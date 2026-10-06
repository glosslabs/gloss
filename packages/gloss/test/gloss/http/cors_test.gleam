import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import gleeunit/should
import gloss/http/cors
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import http_support.{header, request}

fn routes() {
  router.new()
  |> router.get("/notes", fn(_, _) {
    reply.text(200, "notes") |> response.set_header("x-total", "3")
  })
}

fn handle(config: cors.Config, req) {
  server.new(routes(), Nil)
  |> server.with(cors.middleware(config))
  |> server.handle(req)
}

fn with_headers(req, headers: List(#(String, String))) {
  list.fold(headers, req, fn(req, h) { request.set_header(req, h.0, h.1) })
}

fn preflight(origin: String, method: String, headers: String) {
  request(http.Options, "/notes")
  |> with_headers([
    #("origin", origin),
    #("access-control-request-method", method),
    #("access-control-request-headers", headers),
  ])
}

const app = "https://app.example.com"

pub fn preflight_for_an_allowed_origin_test() {
  let config = cors.new() |> cors.allow_origin(app)
  let res = handle(config, preflight(app, "PUT", "Content-Type"))
  res.status |> should.equal(204)
  header(res, "access-control-allow-origin") |> should.equal(app)
  header(res, "access-control-allow-methods")
  |> should.equal("GET, HEAD, POST, PUT, PATCH, DELETE")
  header(res, "access-control-allow-headers")
  |> should.equal("content-type, authorization")
  header(res, "access-control-max-age") |> should.equal("600")
  string.contains(header(res, "vary"), "origin") |> should.be_true
}

pub fn preflight_refusals_test() {
  let config = cors.new() |> cors.allow_origin(app)
  // Another origin, a method not allowed, a header not allowed.
  [
    preflight("https://evil.example", "GET", ""),
    preflight(app, "TRACE", ""),
    preflight(app, "GET", "x-secret"),
  ]
  |> list.each(fn(req) {
    let res = handle(config, req)
    res.status |> should.equal(204)
    header(res, "access-control-allow-origin") |> should.equal("")
  })
}

pub fn actual_requests_test() {
  let config =
    cors.new()
    |> cors.allow_origin(app)
    |> cors.expose_headers(["x-total"])
  let res =
    handle(
      config,
      request(http.Get, "/notes") |> request.set_header("origin", app),
    )
  res.status |> should.equal(200)
  header(res, "access-control-allow-origin") |> should.equal(app)
  header(res, "access-control-expose-headers") |> should.equal("x-total")
  header(res, "access-control-allow-credentials") |> should.equal("")

  let res =
    handle(
      config,
      request(http.Get, "/notes")
        |> request.set_header("origin", "https://evil.example"),
    )
  res.status |> should.equal(200)
  header(res, "access-control-allow-origin") |> should.equal("")
  header(res, "vary") |> should.equal("origin")
}

pub fn any_origin_test() {
  let req =
    request(http.Get, "/notes") |> request.set_header("origin", "https://x.dev")
  handle(cors.new() |> cors.allow_any_origin, req)
  |> header("access-control-allow-origin")
  |> should.equal("*")
  // Credentials can't be combined with `*`: the origin is named instead.
  let res =
    handle(
      cors.new() |> cors.allow_any_origin |> cors.allow_credentials(True),
      req,
    )
  header(res, "access-control-allow-origin") |> should.equal("https://x.dev")
  header(res, "access-control-allow-credentials") |> should.equal("true")
}

pub fn origin_predicate_test() {
  let config =
    cors.new()
    |> cors.allow_origin_when(string.ends_with(_, ".example.com"))
  let get = fn(origin) {
    handle(
      config,
      request(http.Get, "/notes") |> request.set_header("origin", origin),
    )
    |> header("access-control-allow-origin")
  }
  get("https://a.example.com") |> should.equal("https://a.example.com")
  get("https://example.org") |> should.equal("")
}

pub fn requests_without_origin_are_untouched_test() {
  let res =
    handle(cors.new() |> cors.allow_any_origin, request(http.Get, "/notes"))
  header(res, "access-control-allow-origin") |> should.equal("")
  header(res, "vary") |> should.equal("")
}

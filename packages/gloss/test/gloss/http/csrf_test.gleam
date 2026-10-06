import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/list
import gleeunit/should
import gloss/http/csrf
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import gloss/tracer
import http_support.{drain, request}

fn post(headers: List(#(String, String))) {
  list.fold(headers, request(http.Post, "/"), fn(req, h) {
    request.set_header(req, h.0, h.1)
  })
}

fn allowed(config: csrf.Config, headers: List(#(String, String))) -> Bool {
  csrf.check(config, post(headers)) == Ok(Nil)
}

pub fn safe_methods_always_pass_test() {
  csrf.check(
    csrf.new(),
    request(http.Get, "/") |> request.set_header("sec-fetch-site", "cross-site"),
  )
  |> should.equal(Ok(Nil))
}

pub fn fetch_metadata_test() {
  allowed(csrf.new(), [#("sec-fetch-site", "same-origin")]) |> should.be_true
  allowed(csrf.new(), [#("sec-fetch-site", "none")]) |> should.be_true
  allowed(csrf.new(), [#("sec-fetch-site", "same-site")]) |> should.be_false
  allowed(csrf.new(), [#("sec-fetch-site", "cross-site")]) |> should.be_false
}

pub fn trusted_origins_pass_cross_site_test() {
  let config = csrf.new() |> csrf.trust("https://Admin.example.com")
  allowed(config, [
    #("sec-fetch-site", "same-site"),
    #("origin", "https://admin.example.com"),
  ])
  |> should.be_true
  allowed(config, [
    #("sec-fetch-site", "cross-site"),
    #("origin", "https://evil.example"),
  ])
  |> should.be_false
}

pub fn origin_must_match_host_without_fetch_metadata_test() {
  let config = csrf.new()
  allowed(config, [
    #("origin", "http://localhost:4000"),
    #("host", "localhost:4000"),
  ])
  |> should.be_true
  allowed(config, [#("origin", "https://example.com"), #("host", "example.com")])
  |> should.be_true
  allowed(config, [
    #("origin", "https://example.com"),
    #("host", "example.com:443"),
  ])
  |> should.be_true
  allowed(config, [
    #("origin", "https://evil.example"),
    #("host", "example.com"),
  ])
  |> should.be_false
  allowed(config, [#("origin", "null"), #("host", "example.com")])
  |> should.be_false
  allowed(config, [#("origin", "http://[::1]:4000"), #("host", "[::1]:4000")])
  |> should.be_true
}

pub fn non_browser_requests_pass_test() {
  allowed(csrf.new(), []) |> should.be_true
}

pub fn middleware_rejects_and_reports_test() {
  let events = process.new_subject()
  let routes =
    router.new()
    |> router.with(csrf.protect)
    |> router.post("/", fn(_, _) { reply.empty(204) })
  let builder =
    server.new(routes, Nil)
    |> server.tracer(tracer.new() |> tracer.handle(process.send(events, _)))

  server.handle(builder, post([#("sec-fetch-site", "cross-site")])).status
  |> should.equal(403)
  drain(events)
  |> list.any(fn(event) {
    case event {
      tracer.Point(name: "csrf.rejected", level: tracer.Warning, ..) -> True
      _ -> False
    }
  })
  |> should.be_true

  server.handle(builder, post([#("sec-fetch-site", "same-origin")])).status
  |> should.equal(204)
}

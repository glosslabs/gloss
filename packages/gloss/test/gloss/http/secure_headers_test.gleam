import gleam/http
import gleam/http/response
import gleam/option.{None, Some}
import gleeunit/should
import gloss/http/reply
import gloss/http/router
import gloss/http/secure_headers
import gloss/http/server
import http_support.{header, request}

fn routes() {
  router.new()
  |> router.get("/", fn(_, _) { reply.html(200, "<p>hi</p>") })
  |> router.get("/embed", fn(_, _) {
    reply.html(200, "<p>embed</p>")
    |> response.set_header("content-security-policy", "frame-ancestors *")
  })
}

fn get(middleware, path: String) {
  server.new(routes(), Nil)
  |> server.with(middleware)
  |> server.handle(request(http.Get, path))
}

pub fn defaults_test() {
  let res = get(secure_headers.protect, "/")
  header(res, "content-security-policy")
  |> should.equal(
    "default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'",
  )
  header(res, "strict-transport-security")
  |> should.equal("max-age=63072000; includeSubDomains")
  header(res, "x-content-type-options") |> should.equal("nosniff")
  header(res, "x-frame-options") |> should.equal("DENY")
  header(res, "referrer-policy")
  |> should.equal("strict-origin-when-cross-origin")
  header(res, "cross-origin-opener-policy") |> should.equal("same-origin")
}

pub fn error_replies_get_the_headers_test() {
  let res = get(secure_headers.protect, "/missing")
  res.status |> should.equal(404)
  header(res, "x-content-type-options") |> should.equal("nosniff")
}

pub fn handler_headers_win_test() {
  let res = get(secure_headers.protect, "/embed")
  header(res, "content-security-policy") |> should.equal("frame-ancestors *")
  header(res, "x-frame-options") |> should.equal("DENY")
}

pub fn headers_can_be_changed_or_left_out_test() {
  let config =
    secure_headers.new()
    |> secure_headers.content_security_policy(Some("default-src 'none'"))
    |> secure_headers.strict_transport_security(None)
    |> secure_headers.frame_options(None)
    |> secure_headers.referrer_policy(Some("no-referrer"))
    |> secure_headers.cross_origin_opener_policy(None)
  let res = get(secure_headers.middleware(config), "/")
  header(res, "content-security-policy") |> should.equal("default-src 'none'")
  header(res, "strict-transport-security") |> should.equal("")
  header(res, "x-frame-options") |> should.equal("")
  header(res, "referrer-policy") |> should.equal("no-referrer")
  header(res, "cross-origin-opener-policy") |> should.equal("")
  header(res, "x-content-type-options") |> should.equal("nosniff")
}

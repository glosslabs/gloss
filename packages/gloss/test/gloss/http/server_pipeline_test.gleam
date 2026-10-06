import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import gloss/http/context
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import gloss/logger
import gloss/meta
import gloss/tracer
import http_support.{answer, drain, header, request, trail}

fn routes() {
  router.new()
  |> router.get("/notes/:id", fn(_, ctx) {
    use id <- context.int_param(ctx, "id")
    ctx.log.info("showing", [#("id", meta.Int(id))])
    reply.text(200, "note")
  })
  |> router.get("/boom", fn(_, _) { panic as "kaboom" })
  |> router.get("/down", fn(_, _) { reply.error(503, "down") })
  |> router.post("/notes", answer("created"))
}

fn traced() {
  let events = process.new_subject()
  let builder =
    server.new(routes(), Nil)
    |> server.tracer(tracer.new() |> tracer.handle(process.send(events, _)))
  #(builder, events)
}

pub fn span_for_matched_route_test() {
  let #(builder, events) = traced()
  let res = server.handle(builder, request(http.Get, "/notes/7"))
  res.status |> should.equal(200)
  let assert [tracer.Span(source:, name:, meta:, error:, ..)] = drain(events)
  source |> should.equal("gloss.http")
  name |> should.equal("GET /notes/:id")
  error |> should.equal(None)
  meta.get(meta, "status") |> should.equal(Ok(meta.Int(200)))
  meta.get(meta, "route") |> should.equal(Ok(meta.String("/notes/:id")))
  meta.get(meta, "path") |> should.equal(Ok(meta.String("/notes/7")))
  meta.get(meta, "bytes") |> should.equal(Ok(meta.Int(4)))
}

pub fn panic_is_a_500_and_a_failed_span_test() {
  let #(builder, events) = traced()
  let res = server.handle(builder, request(http.Get, "/boom"))
  res.status |> should.equal(500)
  let assert [tracer.Span(name: "GET /boom", error: Some(error), ..)] =
    drain(events)
  string.contains(error, "kaboom") |> should.be_true
}

pub fn server_error_status_fails_the_span_test() {
  let #(builder, events) = traced()
  server.handle(builder, request(http.Get, "/down")).status
  |> should.equal(503)
  let assert [tracer.Span(error: Some("HTTP 503"), ..)] = drain(events)
}

pub fn unmatched_span_is_named_by_method_test() {
  let #(builder, events) = traced()
  server.handle(builder, request(http.Get, "/missing")).status
  |> should.equal(404)
  let assert [tracer.Span(name: "GET", error: None, ..)] = drain(events)
}

pub fn method_not_allowed_test() {
  let #(builder, _) = traced()
  let res = server.handle(builder, request(http.Delete, "/notes"))
  res.status |> should.equal(405)
  header(res, "allow") |> should.equal("POST")
}

pub fn request_id_test() {
  let entries = process.new_subject()
  let builder =
    server.new(routes(), Nil) |> server.logger(logger.memory(entries))

  let res =
    server.handle(
      builder,
      request(http.Get, "/notes/1") |> request.set_header("x-request-id", "abc"),
    )
  header(res, "x-request-id") |> should.equal("abc")
  let assert [logger.Entry(meta:, ..)] = drain(entries)
  meta
  |> should.equal([
    #("request_id", meta.String("abc")),
    #("route", meta.String("/notes/:id")),
    #("id", meta.Int(1)),
  ])

  let generated =
    server.handle(builder, request(http.Get, "/notes/1"))
    |> header("x-request-id")
  string.length(generated) |> should.equal(32)
}

pub fn server_middleware_wraps_unmatched_requests_test() {
  let builder =
    server.new(routes(), Nil)
    |> server.with(trail("s"))
  server.handle(builder, request(http.Get, "/nope"))
  |> header("x-trail")
  |> should.equal("s")
}

pub fn bad_param_is_a_400_test() {
  let #(builder, _) = traced()
  server.handle(builder, request(http.Get, "/notes/x")).status
  |> should.equal(400)
}

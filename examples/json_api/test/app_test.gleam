import app/config.{Config}
import app/notes
import app/routes/api
import app/server as app_server
import app/state
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/option.{None}
import gleeunit
import gleeunit/should
import gloss/http/reply.{type Request}
import gloss/http/router
import gloss/http/server
import gloss/logger
import gloss/tracer

pub fn main() {
  gleeunit.main()
}

fn call(req: Request) -> Response(BytesTree) {
  session()(req)
}

/// Run several requests against one application.
fn session() -> fn(Request) -> Response(BytesTree) {
  let config =
    Config(
      port: 0,
      environment: "test",
      sentry_dsn: None,
      api_token: "t",
      log_dir: "build/test-log",
    )
  let assert Ok(notes) = notes.start()
  let ctx =
    state.new(config, log: logger.discard(), tracer: tracer.new(), notes:)
  let builder = app_server.builder(config, ctx)
  server.handle(builder, _)
}

fn req(method: http.Method, path: String) -> Request {
  request.new()
  |> request.set_method(method)
  |> request.set_path(path)
  |> request.set_body(<<>>)
}

fn authed(r: Request) -> Request {
  request.set_header(r, "authorization", "Bearer t")
}

fn json_body(r: Request, payload: String) -> Request {
  r
  |> request.set_header("content-type", "application/json")
  |> request.set_body(<<payload:utf8>>)
}

fn body(res: Response(BytesTree)) -> String {
  let assert Ok(text) =
    res.body |> bytes_tree.to_bit_array |> bit_array.to_string
  text
}

pub fn routes_are_valid_test() {
  router.check(api.routes()) |> should.equal(Ok(Nil))
}

pub fn health_test() {
  let res = call(req(http.Get, "/health"))
  res.status |> should.equal(200)
  body(res) |> should.equal("{\"status\":\"ok\"}")
}

pub fn me_requires_a_token_test() {
  call(req(http.Get, "/auth/me")).status |> should.equal(401)
  call(
    req(http.Get, "/auth/me") |> request.set_header("authorization", "Bearer x"),
  ).status
  |> should.equal(401)
  let res = call(req(http.Get, "/auth/me") |> authed)
  res.status |> should.equal(200)
  body(res) |> should.equal("{\"name\":\"api\"}")
}

pub fn notes_lifecycle_test() {
  let send = session()

  let created =
    send(
      req(http.Post, "/notes") |> authed |> json_body("{\"title\":\"milk\"}"),
    )
  created.status |> should.equal(201)
  body(created) |> should.equal("{\"id\":1,\"title\":\"milk\",\"body\":\"\"}")

  let shown = send(req(http.Get, "/notes/1") |> authed)
  shown.status |> should.equal(200)

  let listed = send(req(http.Get, "/notes") |> authed)
  body(listed)
  |> should.equal("{\"notes\":[{\"id\":1,\"title\":\"milk\",\"body\":\"\"}]}")

  send(req(http.Delete, "/notes/1") |> authed).status |> should.equal(204)
  send(req(http.Get, "/notes/1") |> authed).status |> should.equal(404)
}

pub fn notes_require_a_token_test() {
  call(req(http.Get, "/notes")).status |> should.equal(401)
}

pub fn invalid_note_test() {
  let res =
    call(req(http.Post, "/notes") |> authed |> json_body("{\"title\":3}"))
  res.status |> should.equal(422)
}

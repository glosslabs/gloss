import app/config.{Config}
import app/notes
import app/routes/api
import app/server as app_server
import app/state
import gleam/json
import gleam/option.{None}
import gleeunit
import gleeunit/should
import gloss/http/reply.{type Request}
import gloss/http/router
import gloss/http/server
import gloss/logger
import gloss/testing/request
import gloss/testing/response
import gloss/tracer

pub fn main() {
  gleeunit.main()
}

fn call(req: Request) -> response.Response {
  session()(req)
}

/// Run several requests against one application.
fn session() -> fn(Request) -> response.Response {
  let config =
    Config(
      port: 0,
      environment: "test",
      sentry_dsn: None,
      api_token: "t",
      log_dir: "build/test-log",
    )
  let assert Ok(notes) = notes.start()
  let state = state.new(config, notes:)
  let builder =
    app_server.builder(
      config,
      state,
      log: logger.discard(),
      tracer: tracer.new(),
    )
  server.handler(builder)
}

fn authed(r: Request) -> Request {
  request.header(r, "authorization", "Bearer t")
}

pub fn routes_are_valid_test() {
  router.check(api.routes()) |> should.equal(Ok(Nil))
}

pub fn health_test() {
  let res = call(request.get("/health"))
  res.status |> should.equal(200)
  response.text(res) |> should.equal("{\"status\":\"ok\"}")
}

pub fn me_requires_a_token_test() {
  call(request.get("/auth/me")).status |> should.equal(401)
  call(request.get("/auth/me") |> request.header("authorization", "Bearer x")).status
  |> should.equal(401)
  let res = call(request.get("/auth/me") |> authed)
  res.status |> should.equal(200)
  response.text(res) |> should.equal("{\"name\":\"api\"}")
}

pub fn notes_lifecycle_test() {
  let send = session()

  let created =
    send(
      request.post("/notes")
      |> authed
      |> request.json(json.object([#("title", json.string("milk"))])),
    )
  created.status |> should.equal(201)
  response.text(created)
  |> should.equal("{\"id\":1,\"title\":\"milk\",\"body\":\"\"}")

  let shown = send(request.get("/notes/1") |> authed)
  shown.status |> should.equal(200)

  let listed = send(request.get("/notes") |> authed)
  response.text(listed)
  |> should.equal("{\"notes\":[{\"id\":1,\"title\":\"milk\",\"body\":\"\"}]}")

  send(request.delete("/notes/1") |> authed).status |> should.equal(204)
  send(request.get("/notes/1") |> authed).status |> should.equal(404)
}

pub fn notes_require_a_token_test() {
  call(request.get("/notes")).status |> should.equal(401)
}

pub fn invalid_note_test() {
  let res =
    call(
      request.post("/notes")
      |> authed
      |> request.json(json.object([#("title", json.int(3))])),
    )
  res.status |> should.equal(422)
}

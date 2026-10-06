import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import gloss/http/body
import gloss/http/context
import gloss/http/reply
import gloss/http/router
import gloss/http/server.{type Builder}
import gloss/tracer
import http_support.{drain}

type Socket

fn routes() {
  router.new()
  |> router.get("/sleep/:ms", fn(_, ctx) {
    use ms <- context.int_param(ctx, "ms")
    process.sleep(ms)
    reply.text(200, "awake")
  })
  |> router.post("/upload", fn(req, _) {
    use result <- body.stream(req, fn(_) { Ok(Nil) })
    let assert Ok(bytes) = result
    reply.text(200, int.to_string(bytes))
  })
  |> router.get("/die", fn(_, _) {
    process.kill(process.self())
    reply.text(200, "unreachable")
  })
}

fn builder(timeout_ms: Int) -> Builder(Nil) {
  server.new(routes(), Nil)
  |> server.port(0)
  |> server.request_timeout(Some(duration.milliseconds(timeout_ms)))
}

fn get(path: String) -> String {
  "GET " <> path <> " HTTP/1.1\r\n\r\n"
}

pub fn slow_handlers_are_stopped_test() {
  let events = process.new_subject()
  let assert Ok(srv) =
    builder(100)
    |> server.tracer(tracer.new() |> tracer.handle(process.send(events, _)))
    |> server.start
  let assert Ok(socket) = connect(server.port_of(srv))
  send(socket, get("/sleep/1000"))
  let assert Ok(#(503, _, body)) = read_response(socket, 1000)
  body |> should.equal(<<"{\"error\":\"request timed out\"}">>)
  is_closed(socket, 1000) |> should.be_true

  // Fast handlers are unaffected.
  let assert Ok(socket) = connect(server.port_of(srv))
  send(socket, get("/sleep/10"))
  let assert Ok(#(200, _, _)) = read_response(socket, 1000)

  let _ = server.shutdown(srv)
  drain(events)
  |> list.any(fn(event) {
    case event {
      tracer.Point(name: "request.timeout", level: tracer.Warning, ..) -> True
      _ -> False
    }
  })
  |> should.be_true
}

pub fn a_steady_upload_outlasts_the_timeout_test() {
  let assert Ok(srv) = builder(200) |> server.start
  let assert Ok(socket) = connect(server.port_of(srv))
  let piece = string.repeat("u", 70_000)
  send(socket, "POST /upload HTTP/1.1\r\ncontent-length: 280000\r\n\r\n")
  // Four pieces, 150 ms apart: 600 ms in all, against a 200 ms timeout.
  list.each([1, 2, 3, 4], fn(_) {
    send(socket, piece)
    process.sleep(150)
  })
  let assert Ok(#(200, _, body)) = read_response(socket, 1000)
  body |> should.equal(<<"280000">>)
  let _ = server.shutdown(srv)
}

pub fn a_crashed_handler_is_a_500_test() {
  let assert Ok(srv) = builder(1000) |> server.start
  let assert Ok(socket) = connect(server.port_of(srv))
  send(socket, get("/die"))
  let assert Ok(#(500, _, _)) = read_response(socket, 1000)
  let _ = server.shutdown(srv)
}

pub fn the_timeout_can_be_turned_off_test() {
  let assert Ok(srv) =
    builder(50) |> server.request_timeout(None) |> server.start
  let assert Ok(socket) = connect(server.port_of(srv))
  send(socket, get("/sleep/200"))
  let assert Ok(#(200, _, _)) = read_response(socket, 1000)
  let _ = server.shutdown(srv)
}

@external(erlang, "http_client_ffi", "connect")
fn connect(port: Int) -> Result(Socket, Nil)

@external(erlang, "http_client_ffi", "send")
fn send(socket: Socket, data: String) -> Nil

@external(erlang, "http_client_ffi", "read_response")
fn read_response(
  socket: Socket,
  timeout: Int,
) -> Result(#(Int, List(#(String, String)), BitArray), Nil)

@external(erlang, "http_client_ffi", "is_closed")
fn is_closed(socket: Socket, timeout: Int) -> Bool

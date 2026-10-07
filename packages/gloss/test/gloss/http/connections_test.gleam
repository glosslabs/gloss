import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import gloss/http/reply
import gloss/http/router
import gloss/http/server.{type Builder}
import gloss/tracer
import http_support.{drain}

type Socket

fn builder(max: option.Option(Int)) -> Builder(Nil) {
  router.new()
  |> router.get("/", fn(_, _) { reply.text(200, "hi") })
  |> server.new(Nil)
  |> server.port(0)
  |> server.max_connections(max)
}

const get = "GET / HTTP/1.1\r\n\r\n"

/// Connect and complete one request, so the server holds the connection.
fn served(port: Int) -> Socket {
  let assert Ok(socket) = connect(port)
  send(socket, get)
  let assert Ok(#(200, _, _)) = read_response(socket, 1000)
  socket
}

pub fn clients_past_the_cap_wait_for_room_test() {
  let events = process.new_subject()
  let assert Ok(srv) =
    builder(Some(2))
    |> server.tracer(tracer.new() |> tracer.handle(process.send(events, _)))
    |> server.start
  let port = server.port_of(srv)
  let first = served(port)
  let _second = served(port)

  // The third client is left in the backlog: no answer yet.
  let assert Ok(third) = connect(port)
  send(third, get)
  read_response(third, 300) |> should.equal(Error(Nil))

  // When a connection closes, the waiting client is served.
  close(first)
  let assert Ok(#(200, _, _)) = read_response(third, 1000)

  drain(events)
  |> list.filter(fn(event) {
    case event {
      tracer.Point(name: "connections.saturated", level: tracer.Warning, ..) ->
        True
      _ -> False
    }
  })
  |> list.length
  // Full at two connections, and full again once the waiting client took
  // the freed slot.
  |> should.equal(2)
  let _ = server.shutdown(srv)
}

pub fn no_cap_test() {
  let assert Ok(srv) = builder(None) |> server.start
  let port = server.port_of(srv)
  list.repeat(Nil, 20) |> list.each(fn(_) { served(port) })
  let _ = server.shutdown(srv)
}

pub fn shutdown_while_at_the_cap_test() {
  let assert Ok(srv) = builder(Some(1)) |> server.start
  let port = server.port_of(srv)
  let _held = served(port)
  let assert Ok(waiting) = connect(port)
  send(waiting, get)
  read_response(waiting, 200) |> should.equal(Error(Nil))
  server.shutdown(srv) |> should.equal(Ok(Nil))
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

@external(erlang, "http_client_ffi", "close")
fn close(socket: Socket) -> Nil

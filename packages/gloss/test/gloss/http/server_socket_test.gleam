import gleam/erlang/process
import gleam/list
import gleam/otp/static_supervisor
import gleam/time/duration
import gleeunit/should
import gloss/http/body
import gloss/http/context
import gloss/http/reply
import gloss/http/router
import gloss/http/server.{type Builder, type Server}
import gloss/tracer
import http_support.{answer, drain}

type Socket

type Reply =
  #(Int, List(#(String, String)), BitArray)

@external(erlang, "http_client_ffi", "connect")
fn connect(port: Int) -> Result(Socket, Nil)

@external(erlang, "http_client_ffi", "send")
fn send(socket: Socket, data: String) -> Nil

@external(erlang, "http_client_ffi", "read_response")
fn read_response(socket: Socket, timeout: Int) -> Result(Reply, Nil)

@external(erlang, "http_client_ffi", "is_closed")
fn is_closed(socket: Socket, timeout: Int) -> Bool

@external(erlang, "http_client_ffi", "close")
fn close(socket: Socket) -> Nil

fn routes() {
  router.new()
  |> router.get("/hello", answer("hello"))
  |> router.post("/echo", fn(req, _) {
    use text <- body.text(req)
    reply.text(200, text)
  })
  |> router.get("/slow/:ms", fn(_, ctx) {
    use ms <- context.int_param(ctx, "ms")
    process.sleep(ms)
    reply.text(200, "slow")
  })
}

fn builder() -> Builder(Nil) {
  server.new(routes(), Nil) |> server.port(0)
}

fn start(builder: Builder(Nil)) -> #(Server, Int) {
  let assert Ok(srv) = server.start(builder)
  #(srv, server.port_of(srv))
}

fn get(path: String) -> String {
  "GET " <> path <> " HTTP/1.1\r\nhost: localhost\r\n\r\n"
}

fn header(reply: Reply, name: String) -> String {
  case list.key_find(reply.1, name) {
    Ok(value) -> value
    Error(Nil) -> ""
  }
}

pub fn keep_alive_serves_several_requests_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(socket, get("/hello"))
  let assert Ok(first) = read_response(socket, 1000)
  first.0 |> should.equal(200)
  first.2 |> should.equal(<<"hello">>)
  header(first, "connection") |> should.equal("keep-alive")

  send(socket, get("/missing"))
  let assert Ok(second) = read_response(socket, 1000)
  second.0 |> should.equal(404)
  close(socket)
  server.shutdown(srv) |> should.equal(Ok(Nil))
}

pub fn connection_close_is_honoured_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(socket, "GET /hello HTTP/1.1\r\nconnection: close\r\n\r\n")
  let assert Ok(reply) = read_response(socket, 1000)
  header(reply, "connection") |> should.equal("close")
  is_closed(socket, 1000) |> should.be_true
  server.shutdown(srv) |> should.equal(Ok(Nil))
}

pub fn body_is_read_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(socket, "POST /echo HTTP/1.1\r\ncontent-length: 5\r\n\r\nhello")
  let assert Ok(reply) = read_response(socket, 1000)
  reply.2 |> should.equal(<<"hello">>)
  close(socket)
  let _ = server.shutdown(srv)
}

pub fn expect_continue_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(
    socket,
    "POST /echo HTTP/1.1\r\ncontent-length: 2\r\nexpect: 100-continue\r\n\r\n",
  )
  let assert Ok(continue) = read_response(socket, 1000)
  continue.0 |> should.equal(100)
  send(socket, "hi")
  let assert Ok(reply) = read_response(socket, 1000)
  reply.2 |> should.equal(<<"hi">>)
  close(socket)
  let _ = server.shutdown(srv)
}

pub fn head_request_has_no_body_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(socket, "HEAD /hello HTTP/1.1\r\n\r\n")
  send(socket, get("/missing"))
  // The HEAD response announces 5 bytes but sends none, so the next
  // response follows its headers directly.
  let assert Ok(head) = read_head(socket, 1000)
  head.0 |> should.equal(200)
  header(head, "content-length") |> should.equal("5")
  let assert Ok(next) = read_response(socket, 1000)
  next.0 |> should.equal(404)
  close(socket)
  let _ = server.shutdown(srv)
}

@external(erlang, "http_client_ffi", "read_head")
fn read_head(socket: Socket, timeout: Int) -> Result(Reply, Nil)

pub fn body_too_large_test() {
  let #(srv, port) = start(builder() |> server.max_body(4))
  let assert Ok(socket) = connect(port)
  send(socket, "POST /echo HTTP/1.1\r\ncontent-length: 5\r\n\r\nhello")
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(413)
  is_closed(socket, 1000) |> should.be_true
  let _ = server.shutdown(srv)
}

pub fn chunked_body_is_not_implemented_test() {
  let events = process.new_subject()
  let #(srv, port) =
    start(
      builder()
      |> server.tracer(tracer.new() |> tracer.handle(process.send(events, _))),
    )
  let assert Ok(socket) = connect(port)
  send(socket, "POST /echo HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n")
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(501)
  let _ = server.shutdown(srv)
  drain(events)
  |> list.any(fn(event) {
    case event {
      tracer.Point(name: "request.rejected", level: tracer.Warning, ..) -> True
      _ -> False
    }
  })
  |> should.be_true
}

pub fn header_timeout_test() {
  let #(srv, port) =
    start(builder() |> server.header_timeout(duration.milliseconds(100)))
  let assert Ok(socket) = connect(port)
  send(socket, "GET /hello HTTP/1.1\r\n")
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(408)
  let _ = server.shutdown(srv)
}

pub fn address_in_use_test() {
  let #(srv, port) = start(builder())
  server.start(builder() |> server.port(port))
  |> should.equal(Error(server.AddressInUse(port)))
  let _ = server.shutdown(srv)
}

pub fn shutdown_waits_for_in_flight_requests_test() {
  let #(srv, port) = start(builder())
  let assert Ok(busy) = connect(port)
  let assert Ok(idle) = connect(port)
  send(idle, get("/hello"))
  let assert Ok(_) = read_response(idle, 1000)

  send(busy, get("/slow/300"))
  process.sleep(50)
  let done = process.new_subject()
  process.spawn(fn() { process.send(done, server.shutdown(srv)) })
  process.sleep(50)

  // The idle connection is closed at once, and no new ones are accepted.
  is_closed(idle, 1000) |> should.be_true
  connect(port) |> should.equal(Error(Nil))

  // The in-flight request completes, then its connection closes.
  let assert Ok(reply) = read_response(busy, 1000)
  reply.2 |> should.equal(<<"slow">>)
  header(reply, "connection") |> should.equal("close")
  process.receive(done, 1000) |> should.equal(Ok(Ok(Nil)))
}

pub fn shutdown_times_out_test() {
  let #(srv, port) =
    start(builder() |> server.shutdown_timeout(duration.milliseconds(100)))
  let assert Ok(busy) = connect(port)
  send(busy, get("/slow/2000"))
  process.sleep(50)
  server.shutdown(srv) |> should.equal(Error(server.TimedOut(1)))
  is_closed(busy, 1000) |> should.be_true
}

pub fn stopping_the_supervisor_drains_test() {
  let ports = process.new_subject()
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(
      builder()
      |> server.on_started(fn(started) { process.send(ports, started.port) })
      |> server.supervised,
    )
    |> static_supervisor.start
  let assert Ok(port) = process.receive(ports, 1000)

  let assert Ok(busy) = connect(port)
  send(busy, get("/slow/200"))
  process.sleep(50)
  let done = process.new_subject()
  process.spawn(fn() {
    stop_supervisor(supervisor.pid)
    process.send(done, Nil)
  })

  let assert Ok(reply) = read_response(busy, 1000)
  reply.2 |> should.equal(<<"slow">>)
  header(reply, "connection") |> should.equal("close")
  process.receive(done, 1000) |> should.equal(Ok(Nil))
  connect(port) |> should.equal(Error(Nil))
}

@external(erlang, "gen_server", "stop")
fn stop_supervisor(pid: process.Pid) -> Nil

pub fn connection_rejections_follow_accept_test() {
  let #(srv, port) = start(builder() |> server.max_body(4))
  let assert Ok(socket) = connect(port)
  send(
    socket,
    "POST /echo HTTP/1.1\r\naccept: text/plain\r\ncontent-length: 5\r\n\r\nhello",
  )
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(413)
  header(reply, "content-type") |> should.equal("text/plain; charset=utf-8")
  reply.2 |> should.equal(<<"content too large">>)
  let _ = server.shutdown(srv)
}

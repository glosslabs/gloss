import gleam/bytes_tree
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/string
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
  |> router.get("/stream/:n", fn(_, ctx) {
    use n <- context.int_param(ctx, "n")
    reply.stream(200, "text/plain", fn(emit) {
      list.repeat(Nil, n)
      |> list.index_map(fn(_, i) { i })
      |> list.each(fn(i) {
        let _ = emit(bytes_tree.from_string(int.to_string(i) <> "\n"))
        Nil
      })
    })
  })
  |> router.get("/forever", fn(_, _) {
    reply.stream(200, "text/plain", fn(emit) { tick(emit) })
  })
  |> router.get("/slow/:ms", fn(_, ctx) {
    use ms <- context.int_param(ctx, "ms")
    process.sleep(ms)
    reply.text(200, "slow")
  })
}

fn tick(emit: reply.Emit) -> Nil {
  case emit(bytes_tree.from_string(".")) {
    Ok(Nil) -> {
      process.sleep(10)
      tick(emit)
    }
    Error(Nil) -> Nil
  }
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
  send(
    socket,
    "GET /hello HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n",
  )
  let assert Ok(reply) = read_response(socket, 1000)
  header(reply, "connection") |> should.equal("close")
  is_closed(socket, 1000) |> should.be_true
  server.shutdown(srv) |> should.equal(Ok(Nil))
}

pub fn body_is_read_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(
    socket,
    "POST /echo HTTP/1.1\r\nhost: localhost\r\ncontent-length: 5\r\n\r\nhello",
  )
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
    "POST /echo HTTP/1.1\r\nhost: localhost\r\ncontent-length: 2\r\nexpect: 100-continue\r\n\r\n",
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
  send(socket, "HEAD /hello HTTP/1.1\r\nhost: localhost\r\n\r\n")
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
  send(
    socket,
    "POST /echo HTTP/1.1\r\nhost: localhost\r\ncontent-length: 5\r\n\r\nhello",
  )
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(413)
  is_closed(socket, 1000) |> should.be_true
  let _ = server.shutdown(srv)
}

pub fn chunked_body_is_read_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(
    socket,
    "POST /echo HTTP/1.1\r\nhost: localhost\r\ntransfer-encoding: chunked\r\n\r\n"
      <> "5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nx-trailer: 1\r\n\r\n",
  )
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(200)
  reply.2 |> should.equal(<<"hello world">>)
  // The connection is still usable afterwards.
  send(socket, get("/hello"))
  let assert Ok(reply) = read_response(socket, 1000)
  reply.2 |> should.equal(<<"hello">>)
  let _ = server.shutdown(srv)
}

pub fn chunked_body_too_large_test() {
  let #(srv, port) = start(builder() |> server.max_body(8))
  let assert Ok(socket) = connect(port)
  send(
    socket,
    "POST /echo HTTP/1.1\r\nhost: localhost\r\ntransfer-encoding: chunked\r\n\r\n"
      <> "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
  )
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(413)
  let _ = server.shutdown(srv)
}

pub fn unsupported_transfer_coding_test() {
  let events = process.new_subject()
  let #(srv, port) =
    start(
      builder()
      |> server.tracer(tracer.new() |> tracer.handle(process.send(events, _))),
    )
  let assert Ok(socket) = connect(port)
  send(
    socket,
    "POST /echo HTTP/1.1\r\nhost: localhost\r\ntransfer-encoding: gzip\r\n\r\n",
  )
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

pub fn conflicting_framing_is_rejected_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(
    socket,
    "POST /echo HTTP/1.1\r\nhost: localhost\r\ntransfer-encoding: chunked\r\ncontent-length: 5\r\n\r\n",
  )
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(400)
  let _ = server.shutdown(srv)
}

pub fn streamed_response_is_chunked_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(socket, get("/stream/3"))
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(200)
  header(reply, "transfer-encoding") |> should.equal("chunked")
  header(reply, "content-length") |> should.equal("")
  reply.2 |> should.equal(<<"0\n1\n2\n">>)
  // Keep-alive survives a stream.
  send(socket, get("/hello"))
  let assert Ok(reply) = read_response(socket, 1000)
  reply.2 |> should.equal(<<"hello">>)
  let _ = server.shutdown(srv)
}

pub fn streamed_response_to_http_1_0_closes_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(socket, "GET /stream/2 HTTP/1.0\r\n\r\n")
  let assert Ok(reply) = read_response(socket, 1000)
  header(reply, "transfer-encoding") |> should.equal("")
  header(reply, "connection") |> should.equal("close")
  reply.2 |> should.equal(<<"0\n1\n">>)
  let _ = server.shutdown(srv)
}

pub fn shutdown_stops_open_streams_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(socket, get("/forever"))
  process.sleep(100)
  // The producer sees emit fail and returns, so shutdown needn't time out.
  server.shutdown(srv) |> should.equal(Ok(Nil))
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(200)
  header(reply, "connection") |> should.equal("keep-alive")
}

pub fn header_timeout_test() {
  let #(srv, port) =
    start(builder() |> server.header_timeout(duration.milliseconds(100)))
  let assert Ok(socket) = connect(port)
  send(socket, "GET /hello HTTP/1.1\r\nhost: localhost\r\n")
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
    "POST /echo HTTP/1.1\r\nhost: localhost\r\naccept: text/plain\r\ncontent-length: 5\r\n\r\nhello",
  )
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(413)
  header(reply, "content-type") |> should.equal("text/plain; charset=utf-8")
  reply.2 |> should.equal(<<"content too large">>)
  let _ = server.shutdown(srv)
}

pub fn missing_host_is_rejected_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(socket, "GET /hello HTTP/1.1\r\n\r\n")
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(400)
  is_closed(socket, 1000) |> should.be_true
  let _ = server.shutdown(srv)
}

pub fn http_1_0_needs_no_host_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(socket, "GET /hello HTTP/1.0\r\n\r\n")
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(200)
  let _ = server.shutdown(srv)
}

pub fn two_hosts_are_rejected_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(socket, "GET /hello HTTP/1.1\r\nhost: a\r\nhost: b\r\n\r\n")
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(400)
  let _ = server.shutdown(srv)
}

pub fn long_uri_is_rejected_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  let path = "/" <> string.repeat("a", 20_000)
  send(socket, get(path))
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(414)
  let _ = server.shutdown(srv)
}

pub fn long_header_is_rejected_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  let big = string.repeat("a", 20_000)
  send(
    socket,
    "GET /hello HTTP/1.1\r\nhost: localhost\r\nx-big: " <> big <> "\r\n\r\n",
  )
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(431)
  let _ = server.shutdown(srv)
}

pub fn unknown_expectation_is_rejected_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(
    socket,
    "POST /echo HTTP/1.1\r\nhost: localhost\r\nexpect: 200-ok\r\ncontent-length: 2\r\n\r\nhi",
  )
  let assert Ok(reply) = read_response(socket, 1000)
  reply.0 |> should.equal(417)
  let _ = server.shutdown(srv)
}

pub fn pipelined_requests_are_answered_in_order_test() {
  let #(srv, port) = start(builder())
  let assert Ok(socket) = connect(port)
  send(
    socket,
    get("/hello")
      <> "POST /echo HTTP/1.1\r\nhost: localhost\r\ncontent-length: 4\r\n\r\npipe"
      <> get("/missing"),
  )
  let assert Ok(first) = read_response(socket, 1000)
  first.2 |> should.equal(<<"hello">>)
  let assert Ok(second) = read_response(socket, 1000)
  second.2 |> should.equal(<<"pipe">>)
  let assert Ok(third) = read_response(socket, 1000)
  third.0 |> should.equal(404)
  close(socket)
  let _ = server.shutdown(srv)
}

pub fn probes_are_answered_before_routing_test() {
  let events = process.new_subject()
  let builder =
    builder()
    |> server.liveness(Some("/health"))
    |> server.readiness(Some("/ready"))
    |> server.with(fn(_) { fn(_, _) { reply.forbidden() } })
    |> server.tracer(tracer.new() |> tracer.handle(process.send(events, _)))
  let #(srv, port) = start(builder)
  let assert Ok(socket) = connect(port)
  send(socket, get("/health"))
  let assert Ok(live) = read_response(socket, 1000)
  live.0 |> should.equal(200)
  live.2 |> should.equal(<<"ok">>)
  send(socket, get("/ready"))
  let assert Ok(ready) = read_response(socket, 1000)
  ready.0 |> should.equal(200)
  ready.2 |> should.equal(<<"ready">>)
  // Other paths still go through the middleware.
  send(socket, get("/hello"))
  let assert Ok(other) = read_response(socket, 1000)
  other.0 |> should.equal(403)
  close(socket)
  let _ = server.shutdown(srv)
  // Only the routed request is traced.
  drain(events)
  |> list.filter(fn(event) {
    case event {
      tracer.Span(..) -> True
      _ -> False
    }
  })
  |> list.length
  |> should.equal(1)
}

pub fn readiness_fails_during_the_drain_delay_test() {
  let builder =
    builder()
    |> server.readiness(Some("/ready"))
    |> server.drain_delay(duration.milliseconds(300))
  let #(srv, port) = start(builder)
  let done = process.new_subject()
  process.spawn(fn() { process.send(done, server.shutdown(srv)) })
  process.sleep(50)

  // Still accepting and serving, but no longer ready.
  let assert Ok(socket) = connect(port)
  send(socket, get("/ready"))
  let assert Ok(ready) = read_response(socket, 1000)
  ready.0 |> should.equal(503)
  ready.2 |> should.equal(<<"draining">>)
  send(socket, get("/hello"))
  let assert Ok(hello) = read_response(socket, 1000)
  hello.0 |> should.equal(200)

  // Once the delay passes, the server drains and stops.
  process.receive(done, 1000) |> should.equal(Ok(Ok(Nil)))
  is_closed(socket, 1000) |> should.be_true
  connect(port) |> should.equal(Error(Nil))
}

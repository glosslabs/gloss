import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import gloss/http/router
import gloss/http/server.{type Server}
import gloss/http/websocket
import http_support.{header, request}

type Socket

/// What the test hears about each socket's life.
type Note {
  Opened(Subject(String))
  ClosedWith(Int, websocket.CloseReason)
}

fn routes(notes: Subject(Note)) {
  tuned_routes(notes, fn(builder) { builder })
}

/// The echo socket, with `tune` applied to its builder.
fn tuned_routes(
  notes: Subject(Note),
  tune: fn(websocket.Builder(Int, String)) -> websocket.Builder(Int, String),
) {
  router.new()
  |> router.get("/echo", fn(req, _) {
    websocket.new(
      on_init: fn(_conn) {
        // Messages sent to `inbox` from other processes reach on_message.
        let inbox = process.new_subject()
        process.send(notes, Opened(inbox))
        #(0, Some(process.new_selector() |> process.select(inbox)))
      },
      on_message: fn(count, conn, message) {
        case message {
          websocket.Text("stop") -> websocket.stop()
          websocket.Text("bye") -> websocket.close(4000, "done here")
          websocket.Text("bad code") -> websocket.close(1005, "")
          websocket.Text(text) -> {
            let _ = websocket.send_text(conn, text)
            websocket.continue(count + 1)
          }
          websocket.Binary(data) -> {
            let _ = websocket.send_binary(conn, data)
            websocket.continue(count + 1)
          }
          websocket.Custom(text) -> {
            let _ = websocket.send_text(conn, "pushed " <> text)
            websocket.continue(count)
          }
        }
      },
      on_close: fn(count, reason) {
        process.send(notes, ClosedWith(count, reason))
      },
    )
    |> tune
    |> websocket.upgrade(req)
  })
}

fn start() -> #(Server, Int, Subject(Note)) {
  start_tuned(fn(builder) { builder })
}

fn start_tuned(
  tune: fn(websocket.Builder(Int, String)) -> websocket.Builder(Int, String),
) -> #(Server, Int, Subject(Note)) {
  let notes = process.new_subject()
  let assert Ok(srv) =
    server.new(tuned_routes(notes, tune), Nil)
    |> server.port(0)
    |> server.start
  #(srv, server.port_of(srv), notes)
}

fn open(port: Int, notes: Subject(Note)) -> #(Socket, Subject(String)) {
  let assert Ok(#(socket, 101, accept)) = connect(port, "/echo")
  accept |> should.equal("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  let assert Ok(Opened(inbox)) = process.receive(notes, 1000)
  #(socket, inbox)
}

pub fn echo_text_and_binary_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  send(socket, 1, <<"hello":utf8>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(1, <<"hello":utf8>>)))
  send(socket, 2, <<1, 2, 3>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(2, <<1, 2, 3>>)))
  let _ = server.shutdown(srv)
}

pub fn ping_is_answered_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  send(socket, 9, <<"are you there":utf8>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(10, <<"are you there":utf8>>)))
  let _ = server.shutdown(srv)
}

pub fn fragments_are_reassembled_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  send(socket, 1, <<"hel":utf8>>, False)
  // A control frame may arrive between fragments.
  send(socket, 9, <<>>, True)
  send(socket, 0, <<"lo ":utf8>>, False)
  send(socket, 0, <<"world":utf8>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(10, <<>>)))
  recv(socket, 1000) |> should.equal(Ok(#(1, <<"hello world":utf8>>)))
  let _ = server.shutdown(srv)
}

pub fn messages_from_other_processes_test() {
  let #(srv, port, notes) = start()
  let #(socket, inbox) = open(port, notes)
  process.send(inbox, "news")
  recv(socket, 1000) |> should.equal(Ok(#(1, <<"pushed news":utf8>>)))
  let _ = server.shutdown(srv)
}

pub fn client_close_is_echoed_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  send(socket, 1, <<"one":utf8>>, True)
  let _ = recv(socket, 1000)
  send(socket, 8, <<1000:16, "see you":utf8>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(8, <<1000:16>>)))
  process.receive(notes, 1000)
  |> should.equal(Ok(ClosedWith(1, websocket.ClientClosed(1000, "see you"))))
  closed(socket, 1000) |> should.be_true
  let _ = server.shutdown(srv)
}

pub fn handler_stop_closes_normally_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  send(socket, 1, <<"stop":utf8>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(8, <<1000:16>>)))
  send(socket, 8, <<1000:16>>, True)
  process.receive(notes, 1000)
  |> should.equal(Ok(ClosedWith(0, websocket.ServerClosed(1000, ""))))
  let _ = server.shutdown(srv)
}

pub fn invalid_utf8_closes_with_1007_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  send(socket, 1, <<0xff, 0xfe>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(8, <<1007:16>>)))
  send(socket, 8, <<1007:16>>, True)
  process.receive(notes, 1000)
  |> should.equal(Ok(ClosedWith(0, websocket.ProtocolError(1007))))
  let _ = server.shutdown(srv)
}

pub fn shutdown_closes_with_going_away_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  let done = process.new_subject()
  process.spawn(fn() { process.send(done, server.shutdown(srv)) })
  recv(socket, 1000) |> should.equal(Ok(#(8, <<1001:16>>)))
  send(socket, 8, <<1001:16>>, True)
  process.receive(notes, 1000)
  |> should.equal(Ok(ClosedWith(0, websocket.ShuttingDown)))
  process.receive(done, 2000) |> should.equal(Ok(Ok(Nil)))
}

pub fn invalid_upgrades_are_refused_test() {
  let builder = server.new(routes(process.new_subject()), Nil)
  let upgrade = fn(version) {
    request(http.Get, "/echo")
    |> request.set_header("upgrade", "websocket")
    |> request.set_header("connection", "keep-alive, Upgrade")
    |> request.set_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    |> request.set_header("sec-websocket-version", version)
  }
  let res = server.handle(builder, upgrade("13"))
  res.status |> should.equal(101)
  header(res, "sec-websocket-accept")
  |> should.equal("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

  let res = server.handle(builder, upgrade("8"))
  res.status |> should.equal(426)
  header(res, "sec-websocket-version") |> should.equal("13")

  server.handle(builder, request(http.Get, "/echo")).status
  |> should.equal(400)
  server.handle(
    builder,
    upgrade("13") |> request.set_header("sec-websocket-key", "short"),
  ).status
  |> should.equal(400)
}

// --- Closing with a code and a reason ----------------------------------------

pub fn close_sends_its_code_and_reason_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  send(socket, 1, <<"bye":utf8>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(8, <<4000:16, "done here":utf8>>)))
  // The server waits for the client's close frame before dropping the socket.
  send(socket, 8, <<4000:16>>, True)
  process.receive(notes, 1000)
  |> should.equal(Ok(ClosedWith(0, websocket.ServerClosed(4000, "done here"))))
  closed(socket, 1000) |> should.be_true
  let _ = server.shutdown(srv)
}

pub fn a_closing_server_waits_a_second_for_the_client_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  send(socket, 1, <<"bye":utf8>>, True)
  let _ = recv(socket, 1000)
  // The client never answers: on_close still runs, after the wait.
  process.receive(notes, 300) |> should.equal(Error(Nil))
  let assert Ok(ClosedWith(0, websocket.ServerClosed(4000, _))) =
    process.receive(notes, 1500)
  let _ = server.shutdown(srv)
}

pub fn a_reserved_close_code_is_sent_as_1000_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  send(socket, 1, <<"bad code":utf8>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(8, <<1000:16>>)))
  let _ = server.shutdown(srv)
}

pub fn a_dropped_connection_is_reported_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  close_socket(socket)
  process.receive(notes, 1000)
  |> should.equal(Ok(ClosedWith(0, websocket.Disconnected)))
  let _ = server.shutdown(srv)
}

// --- Liveness ------------------------------------------------------------------

fn quick_liveness(builder) {
  builder
  |> websocket.ping_interval(Some(duration.milliseconds(50)))
  |> websocket.idle_timeout(Some(duration.milliseconds(150)))
}

pub fn a_silent_client_is_pinged_then_closed_test() {
  let #(srv, port, notes) = start_tuned(quick_liveness)
  let #(socket, _) = open(port, notes)
  recv(socket, 1000) |> should.equal(Ok(#(9, <<>>)))
  // Say nothing: the server closes with 1001 once 150ms pass in silence.
  let assert Ok(#(8, <<1001:16>>)) = skip_pings(socket)
  send(socket, 8, <<1001:16>>, True)
  process.receive(notes, 1000)
  |> should.equal(Ok(ClosedWith(0, websocket.TimedOut)))
  let _ = server.shutdown(srv)
}

pub fn a_client_answering_pings_stays_open_test() {
  let #(srv, port, notes) = start_tuned(quick_liveness)
  let #(socket, _) = open(port, notes)
  // Answer five pings, about 250ms, well past the 150ms idle timeout.
  pong(socket, 5)
  send(socket, 1, <<"still here":utf8>>, True)
  let assert Ok(#(1, <<"still here":utf8>>)) = skip_pings(socket)
  let _ = server.shutdown(srv)
}

pub fn liveness_can_be_turned_off_test() {
  let #(srv, port, notes) =
    start_tuned(fn(builder) {
      builder
      |> websocket.ping_interval(None)
      |> websocket.idle_timeout(None)
    })
  let #(socket, _) = open(port, notes)
  recv(socket, 300) |> should.equal(Error(Nil))
  process.receive(notes, 0) |> should.equal(Error(Nil))
  let _ = server.shutdown(srv)
}

fn skip_pings(socket: Socket) -> Result(#(Int, BitArray), Nil) {
  case recv(socket, 1000) {
    Ok(#(9, _)) -> skip_pings(socket)
    other -> other
  }
}

fn pong(socket: Socket, times: Int) -> Nil {
  case times {
    0 -> Nil
    _ -> {
      let assert Ok(#(9, payload)) = recv(socket, 1000)
      send(socket, 10, payload, True)
      pong(socket, times - 1)
    }
  }
}

// --- Origins -------------------------------------------------------------------

fn upgrade_request() {
  request(http.Get, "/echo")
  |> request.set_header("upgrade", "websocket")
  |> request.set_header("connection", "Upgrade")
  |> request.set_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
  |> request.set_header("sec-websocket-version", "13")
}

pub fn upgrades_from_other_sites_are_refused_test() {
  let builder = server.new(routes(process.new_subject()), Nil)
  let status = fn(req) { server.handle(builder, req).status }

  upgrade_request()
  |> request.set_header("sec-fetch-site", "cross-site")
  |> request.set_header("origin", "https://evil.example")
  |> status
  |> should.equal(403)

  upgrade_request()
  |> request.set_header("origin", "https://evil.example")
  |> status
  |> should.equal(403)

  upgrade_request()
  |> request.set_header("sec-fetch-site", "same-origin")
  |> status
  |> should.equal(101)

  // No browser headers at all: not a page, so nothing to forge.
  upgrade_request() |> status |> should.equal(101)
}

pub fn a_trusted_origin_may_upgrade_test() {
  let notes = process.new_subject()
  let builder =
    server.new(
      tuned_routes(notes, websocket.trust(_, "https://admin.example.com")),
      Nil,
    )
  let res =
    server.handle(
      builder,
      upgrade_request()
        |> request.set_header("sec-fetch-site", "same-site")
        |> request.set_header("origin", "https://admin.example.com"),
    )
  res.status |> should.equal(101)
}

@external(erlang, "ws_client_ffi", "connect")
fn connect(port: Int, path: String) -> Result(#(Socket, Int, String), Nil)

@external(erlang, "ws_client_ffi", "send")
fn send(socket: Socket, opcode: Int, payload: BitArray, fin: Bool) -> Nil

@external(erlang, "ws_client_ffi", "recv")
fn recv(socket: Socket, timeout: Int) -> Result(#(Int, BitArray), Nil)

@external(erlang, "ws_client_ffi", "closed")
fn closed(socket: Socket, timeout: Int) -> Bool

@external(erlang, "ws_client_ffi", "close")
fn close_socket(socket: Socket) -> Nil

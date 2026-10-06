import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/option.{Some}
import gleeunit/should
import gloss/http/router
import gloss/http/server.{type Server}
import gloss/http/websocket
import http_support.{header, request}

type Socket

/// What the test hears about each socket's life.
type Note {
  Opened(Subject(String))
  ClosedWith(Int)
}

fn routes(notes: Subject(Note)) {
  router.new()
  |> router.get("/echo", fn(req, _) {
    websocket.upgrade(
      req,
      on_init: fn(_conn) {
        // Messages sent to `inbox` from other processes reach on_message.
        let inbox = process.new_subject()
        process.send(notes, Opened(inbox))
        #(0, Some(process.new_selector() |> process.select(inbox)))
      },
      on_message: fn(count, conn, message) {
        case message {
          websocket.Text("stop") -> websocket.stop()
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
      on_close: fn(count) { process.send(notes, ClosedWith(count)) },
    )
  })
}

fn start() -> #(Server, Int, Subject(Note)) {
  let notes = process.new_subject()
  let assert Ok(srv) =
    server.new(routes(notes), Nil) |> server.port(0) |> server.start
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
  send(socket, 8, <<1000:16>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(8, <<1000:16>>)))
  process.receive(notes, 1000) |> should.equal(Ok(ClosedWith(1)))
  closed(socket, 1000) |> should.be_true
  let _ = server.shutdown(srv)
}

pub fn handler_stop_closes_normally_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  send(socket, 1, <<"stop":utf8>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(8, <<1000:16>>)))
  process.receive(notes, 1000) |> should.equal(Ok(ClosedWith(0)))
  let _ = server.shutdown(srv)
}

pub fn invalid_utf8_closes_with_1007_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  send(socket, 1, <<0xff, 0xfe>>, True)
  recv(socket, 1000) |> should.equal(Ok(#(8, <<1007:16>>)))
  let _ = server.shutdown(srv)
}

pub fn shutdown_closes_with_going_away_test() {
  let #(srv, port, notes) = start()
  let #(socket, _) = open(port, notes)
  server.shutdown(srv) |> should.equal(Ok(Nil))
  recv(socket, 1000) |> should.equal(Ok(#(8, <<1001:16>>)))
  process.receive(notes, 1000) |> should.equal(Ok(ClosedWith(0)))
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

@external(erlang, "ws_client_ffi", "connect")
fn connect(port: Int, path: String) -> Result(#(Socket, Int, String), Nil)

@external(erlang, "ws_client_ffi", "send")
fn send(socket: Socket, opcode: Int, payload: BitArray, fin: Bool) -> Nil

@external(erlang, "ws_client_ffi", "recv")
fn recv(socket: Socket, timeout: Int) -> Result(#(Int, BitArray), Nil)

@external(erlang, "ws_client_ffi", "closed")
fn closed(socket: Socket, timeout: Int) -> Bool

//// A WebSocket client for tests: connect to a running server, send
//// frames, and wait for what comes back.
////
//// ```gleam
//// let assert Ok(srv) = server.new(routes(), state) |> server.port(0) |> server.start
//// let assert Ok(client) = websocket.connect(server.port_of(srv), "/echo", [])
//// let assert Ok(Nil) = websocket.send_text(client, "hello")
//// assert websocket.receive(client, 1000) == Ok(websocket.Text("hello"))
//// let _ = server.shutdown(srv)
//// ```
////
//// `receive` returns every frame the server sends, pings included, and
//// joins fragmented messages. It answers nothing on its own, so a test can
//// see the server's pings and decide whether to send `send_pong`.

import gleam/bit_array
import gleam/list
import gleam/result

pub opaque type Client {
  Client(socket: Socket, headers: List(#(String, String)))
}

type Socket

pub type ConnectError {
  /// The server answered the upgrade with this status instead of `101`.
  Refused(status: Int)
  Unreachable(reason: String)
}

pub type Message {
  Text(String)
  Binary(BitArray)
  Ping(BitArray)
  Pong(BitArray)
  /// The server closed the socket with this code (1005 when it gave none).
  Close(code: Int, reason: String)
}

pub type ReceiveError {
  /// Nothing arrived in time.
  Timeout
  /// The connection is gone.
  Closed
}

/// Open a socket to `path` on the server listening on `port` at
/// 127.0.0.1, with extra request headers such as `#("origin", ..)`.
pub fn connect(
  port: Int,
  path: String,
  headers: List(#(String, String)),
) -> Result(Client, ConnectError) {
  case ffi_connect(port, path, headers, 1000) {
    Ok(#(socket, 101, headers)) -> Ok(Client(socket:, headers:))
    Ok(#(socket, status, _)) -> {
      ffi_close(socket)
      Error(Refused(status))
    }
    Error(reason) -> Error(reason)
  }
}

/// The headers of the server's `101` response, names lowercased.
pub fn headers(client: Client) -> List(#(String, String)) {
  client.headers
}

/// One header of the server's `101` response.
pub fn header(client: Client, name: String) -> Result(String, Nil) {
  list.key_find(client.headers, name)
}

pub fn send_text(client: Client, text: String) -> Result(Nil, Nil) {
  send_frame(client, True, 1, bit_array.from_string(text))
}

pub fn send_binary(client: Client, data: BitArray) -> Result(Nil, Nil) {
  send_frame(client, True, 2, data)
}

pub fn send_ping(client: Client, data: BitArray) -> Result(Nil, Nil) {
  send_frame(client, True, 9, data)
}

pub fn send_pong(client: Client, data: BitArray) -> Result(Nil, Nil) {
  send_frame(client, True, 10, data)
}

pub fn send_close(
  client: Client,
  code: Int,
  reason: String,
) -> Result(Nil, Nil) {
  send_frame(client, True, 8, <<code:16, reason:utf8>>)
}

/// One masked frame of any kind, for testing how a server handles
/// fragments, unknown opcodes or bad payloads. `opcode` is the number from
/// RFC 6455: 0 continuation, 1 text, 2 binary, 8 close, 9 ping, 10 pong.
pub fn send_frame(
  client: Client,
  fin: Bool,
  opcode: Int,
  payload: BitArray,
) -> Result(Nil, Nil) {
  ffi_send_frame(client.socket, fin, opcode, payload)
}

/// The next message, waiting up to `timeout` milliseconds for each frame.
pub fn receive(client: Client, timeout: Int) -> Result(Message, ReceiveError) {
  use #(fin, opcode, payload) <- result.try(ffi_recv_frame(
    client.socket,
    timeout,
  ))
  case opcode {
    1 | 2 if !fin -> continue(client, timeout, opcode, [payload])
    _ -> Ok(message(opcode, payload))
  }
}

fn continue(
  client: Client,
  timeout: Int,
  opcode: Int,
  pieces: List(BitArray),
) -> Result(Message, ReceiveError) {
  use #(fin, next, payload) <- result.try(ffi_recv_frame(client.socket, timeout))
  case next, fin {
    0, True ->
      Ok(message(opcode, bit_array.concat(list.reverse([payload, ..pieces]))))
    0, False -> continue(client, timeout, opcode, [payload, ..pieces])
    // A control frame between fragments: skip it and keep assembling.
    _, _ -> continue(client, timeout, opcode, pieces)
  }
}

fn message(opcode: Int, payload: BitArray) -> Message {
  case opcode, payload {
    1, _ ->
      case bit_array.to_string(payload) {
        Ok(text) -> Text(text)
        Error(Nil) -> Binary(payload)
      }
    8, <<code:16, reason:bytes>> ->
      Close(code, bit_array.to_string(reason) |> result.unwrap(""))
    8, _ -> Close(1005, "")
    9, _ -> Ping(payload)
    10, _ -> Pong(payload)
    _, _ -> Binary(payload)
  }
}

/// Drop the connection without a close frame, as a client that went away.
pub fn disconnect(client: Client) -> Nil {
  ffi_close(client.socket)
}

/// Whether the server closes the connection within `timeout` milliseconds.
pub fn wait_closed(client: Client, timeout: Int) -> Bool {
  ffi_closed(client.socket, timeout)
}

@external(erlang, "gloss@testing@websocket_ffi", "connect")
fn ffi_connect(
  port: Int,
  path: String,
  headers: List(#(String, String)),
  timeout: Int,
) -> Result(#(Socket, Int, List(#(String, String))), ConnectError)

@external(erlang, "gloss@testing@websocket_ffi", "send_frame")
fn ffi_send_frame(
  socket: Socket,
  fin: Bool,
  opcode: Int,
  payload: BitArray,
) -> Result(Nil, Nil)

@external(erlang, "gloss@testing@websocket_ffi", "recv_frame")
fn ffi_recv_frame(
  socket: Socket,
  timeout: Int,
) -> Result(#(Bool, Int, BitArray), ReceiveError)

@external(erlang, "gloss@testing@websocket_ffi", "close")
fn ffi_close(socket: Socket) -> Nil

@external(erlang, "gloss@testing@websocket_ffi", "closed")
fn ffi_closed(socket: Socket, timeout: Int) -> Bool

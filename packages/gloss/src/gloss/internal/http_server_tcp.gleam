//// Bindings to the socket and process primitives in
//// `gloss@http@server_ffi.erl`.

import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Pid}

pub type ListenSocket

pub type Socket

pub type ListenError {
  AddressInUse
  InvalidInterface
  Other(String)
}

pub type AcceptError {
  /// The listen socket was closed: stop accepting.
  Closed
  Failed(String)
}

/// What arrived on a connection, from `next`.
pub type Event {
  RequestLine(method: String, target: String, version: #(Int, Int))
  Header(name: String, value: String)
  EndOfHeaders
  BadRequest(line: String)
  ConnectionClosed
  /// The server asked this connection to finish up.
  Drain
  Timeout
}

@external(erlang, "gloss@http@server_ffi", "listen")
pub fn listen(
  interface: String,
  port: Int,
  backlog: Int,
) -> Result(ListenSocket, ListenError)

@external(erlang, "gloss@http@server_ffi", "port")
pub fn port(socket: ListenSocket) -> Int

@external(erlang, "gloss@http@server_ffi", "close")
pub fn close_listener(socket: ListenSocket) -> Nil

@external(erlang, "gloss@http@server_ffi", "accept")
pub fn accept(socket: ListenSocket) -> Result(Socket, AcceptError)

@external(erlang, "gloss@http@server_ffi", "controlling_process")
pub fn controlling_process(socket: Socket, pid: Pid) -> Nil

@external(erlang, "gloss@http@server_ffi", "close")
pub fn close(socket: Socket) -> Nil

@external(erlang, "gloss@http@server_ffi", "send")
pub fn send(socket: Socket, data: BytesTree) -> Result(Nil, Nil)

@external(erlang, "gloss@http@server_ffi", "next")
pub fn next(socket: Socket, timeout: Int) -> Event

@external(erlang, "gloss@http@server_ffi", "read_body")
pub fn read_body(
  socket: Socket,
  length: Int,
  timeout: Int,
) -> Result(BitArray, Nil)

/// Whether the server has asked this process to drain, consuming the
/// request.
@external(erlang, "gloss@http@server_ffi", "drain_requested")
pub fn drain_requested() -> Bool

@external(erlang, "gloss@http@server_ffi", "request_drain")
pub fn request_drain(connection: Pid) -> Nil

@external(erlang, "gloss@http@server_ffi", "await_go")
pub fn await_go() -> Nil

@external(erlang, "gloss@http@server_ffi", "go")
pub fn go(connection: Pid) -> Nil

@external(erlang, "gloss@http@server_ffi", "http_date")
pub fn http_date() -> String

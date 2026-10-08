//// Client sockets over TCP or TLS, for the database and cache drivers
//// (`gloss_pg`, `gloss_mysql`, `gloss_redis`). Sockets start passive and
//// raw: the driver frames its protocol and reads with a timeout, or turns
//// the socket active and reads messages.

import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}

pub type Socket

pub type RecvError {
  Timeout
  Closed
  Failed(String)
}

/// What a message to an active socket's owner means.
pub type Event {
  Data(BitArray)
  /// The socket closed, or failed for `reason`.
  Disconnected(reason: String)
  /// The message isn't about this socket.
  NotSocket
}

@external(erlang, "gloss@internal@socket_ffi", "connect")
pub fn connect(host: String, port: Int, timeout: Int) -> Result(Socket, String)

/// Start TLS. With `verify` the server's certificate must chain to a
/// system CA and match `host`.
@external(erlang, "gloss@internal@socket_ffi", "upgrade")
pub fn upgrade(
  socket: Socket,
  host: String,
  verify: Bool,
  timeout: Int,
) -> Result(Socket, String)

@external(erlang, "gloss@internal@socket_ffi", "send")
pub fn send(socket: Socket, data: BytesTree) -> Result(Nil, String)

/// `length` bytes, or whatever is available when `length` is 0.
@external(erlang, "gloss@internal@socket_ffi", "recv")
pub fn recv(
  socket: Socket,
  length: Int,
  timeout: Int,
) -> Result(BitArray, RecvError)

/// Whether an idle socket is still usable: nothing to read and not closed.
@external(erlang, "gloss@internal@socket_ffi", "alive")
pub fn alive(socket: Socket) -> Bool

/// Make `pid` the socket's owner.
@external(erlang, "gloss@internal@socket_ffi", "transfer")
pub fn transfer(socket: Socket, pid: Pid) -> Nil

@external(erlang, "gloss@internal@socket_ffi", "close")
pub fn close(socket: Socket) -> Nil

/// Deliver the next bytes received as a message to the owner.
@external(erlang, "gloss@internal@socket_ffi", "activate_once")
pub fn activate_once(socket: Socket) -> Nil

/// Deliver everything received as messages to the owner.
@external(erlang, "gloss@internal@socket_ffi", "activate")
pub fn activate(socket: Socket) -> Nil

/// Back to passive mode, returning bytes delivered but not yet handled.
@external(erlang, "gloss@internal@socket_ffi", "deactivate")
pub fn deactivate(socket: Socket) -> BitArray

@external(erlang, "gloss@internal@socket_ffi", "event")
pub fn event(socket: Socket, message: Dynamic) -> Event

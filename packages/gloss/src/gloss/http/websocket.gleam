//// WebSockets: upgrade a request, then exchange messages until either side
//// closes.
////
//// ```gleam
//// pub fn echo(req: Request, _ctx: Context(State)) -> Response {
////   websocket.new(
////     on_init: fn(_conn) { #(Nil, None) },
////     on_message: fn(state, conn, message) {
////       case message {
////         websocket.Text(text) -> {
////           let _ = websocket.send_text(conn, text)
////           websocket.continue(state)
////         }
////         websocket.Binary(_) | websocket.Custom(_) ->
////           websocket.continue(state)
////       }
////     },
////     on_close: fn(_state, _reason) { Nil },
////   )
////   |> websocket.upgrade(req)
//// }
//// ```
////
//// After the `101 Switching Protocols` response the connection's process
//// runs the socket: it calls `on_message` for each text or binary message,
//// and for each message from the selector `on_init` returned (for
//// messages from other processes, e.g. a chat room). It answers pings,
//// reassembles fragmented messages, and refuses messages over 16 MiB.
////
//// ## Liveness
////
//// The server pings the client every 30 seconds, and closes a socket it
//// has heard nothing from (no message, pong or ping) for 60 seconds with
//// code 1001. Proxies tend to cut quiet connections after about a minute,
//// and a client that vanished without closing would otherwise hold its
//// process for hours. Change either with `ping_interval` and
//// `idle_timeout`.
////
//// ## Closing
////
//// Return `stop()` to close normally (code 1000), or `close(code, reason)`
//// for another code. When the server closes, it waits up to a second for
//// the client's close frame before dropping the connection. `on_close`
//// runs once, however the socket ends, and is told why as a `CloseReason`.
////
//// ## Origins
////
//// An upgrade is a `GET`, so CSRF protection doesn't see it, yet the
//// browser sends the user's cookies with it. To stop another site opening
//// a socket as a signed-in user, an upgrade from a page on another site is
//// refused with `403`, judged by `Sec-Fetch-Site` and `Origin` as
//// `gloss/http/csrf` does. Allow another origin of yours with `trust`.
//// Clients other than browsers send neither header and are let through.
////
//// A request that isn't a valid WebSocket upgrade gets `400`, or `426` for
//// an unsupported protocol version.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gloss/http/reply.{type Request, type Response}
import gloss/internal/http_origin as origin
import gloss/internal/http_server_tcp.{type Socket} as tcp
import gloss/internal/http_websocket_frame.{
  type Frame, type Opcode, BinaryFrame, CloseFrame, Continuation, Frame,
  Incomplete, Invalid, PingFrame, PongFrame, TextFrame,
} as frame

/// The socket, for sending. Only usable from the connection's own process,
/// that is, inside `on_init` and `on_message`.
pub opaque type Connection {
  Connection(socket: Socket)
}

pub type Message(custom) {
  Text(String)
  Binary(BitArray)
  /// A message from the selector returned by `on_init`.
  Custom(custom)
}

pub opaque type Next(state) {
  Continue(state)
  Close(code: Int, reason: String)
}

pub fn continue(state: state) -> Next(state) {
  Continue(state)
}

/// Close the socket normally (code 1000).
pub fn stop() -> Next(state) {
  Close(1000, "")
}

/// Close the socket with `code` and a `reason` for the client, e.g.
/// `close(4001, "signed out")`. Use 1000 for a normal close, 1008 for a
/// policy violation, or a code of your own from 4000 to 4999. A code the
/// protocol doesn't allow a server to send is sent as 1000, and a reason
/// is cut to 123 bytes.
pub fn close(code: Int, reason: String) -> Next(state) {
  Close(code, reason)
}

/// How a socket ended, as `on_close` is told.
pub type CloseReason {
  /// The client sent a close frame. `code` is 1005 when it gave none.
  ClientClosed(code: Int, reason: String)
  /// A handler returned `stop()` or `close(code, reason)`.
  ServerClosed(code: Int, reason: String)
  /// Nothing arrived for the idle timeout; closed with 1001.
  TimedOut
  /// The client broke the protocol, so the server closed with `code`:
  /// 1002 for a malformed frame, 1007 for text that isn't UTF-8, 1009 for
  /// a message over the size limit.
  ProtocolError(code: Int)
  /// The server is shutting down; closed with 1001.
  ShuttingDown
  /// The connection dropped without a close frame.
  Disconnected
}

/// How to run a socket. Make one with `new`, adjust it, then `upgrade`.
pub opaque type Builder(state, custom) {
  Builder(
    handlers: Handlers(state, custom),
    ping_interval: Option(Duration),
    idle_timeout: Option(Duration),
    trusted: List(String),
  )
}

/// The largest message accepted, assembled from all its fragments.
const max_message = 16_777_216

/// How long a closing server waits for the client's close frame.
const close_wait_ms = 1000

/// A socket with these callbacks: ping every 30 seconds, close after 60
/// seconds of silence, and refuse upgrades from other sites.
pub fn new(
  on_init on_init: fn(Connection) -> #(state, Option(Selector(custom))),
  on_message on_message: fn(state, Connection, Message(custom)) -> Next(state),
  on_close on_close: fn(state, CloseReason) -> Nil,
) -> Builder(state, custom) {
  Builder(
    handlers: Handlers(on_init:, on_message:, on_close:),
    ping_interval: Some(duration.seconds(30)),
    idle_timeout: Some(duration.seconds(60)),
    trusted: [],
  )
}

/// How often to ping the client, or `None` never to.
pub fn ping_interval(
  builder: Builder(state, custom),
  interval: Option(Duration),
) -> Builder(state, custom) {
  Builder(..builder, ping_interval: interval)
}

/// How long the socket may go without hearing from the client before it is
/// closed with 1001, or `None` to keep it open however quiet it is. Keep it
/// longer than the ping interval, or a live client will be closed.
pub fn idle_timeout(
  builder: Builder(state, custom),
  timeout: Option(Duration),
) -> Builder(state, custom) {
  Builder(..builder, idle_timeout: timeout)
}

/// Also accept upgrades from pages on `origin`, e.g.
/// `"https://admin.example.com"`: scheme, host and any non-default port,
/// with no path.
pub fn trust(
  builder: Builder(state, custom),
  origin: String,
) -> Builder(state, custom) {
  Builder(..builder, trusted: [string.lowercase(origin), ..builder.trusted])
}

/// Answer `req` with `101 Switching Protocols` and run the socket, or
/// refuse it: `403` from another site, `426` for another protocol version,
/// `400` when it isn't a WebSocket upgrade.
pub fn upgrade(builder: Builder(state, custom), req: Request) -> Response {
  case handshake(req, builder.trusted) {
    Error(response) -> response
    Ok(accept) ->
      response.new(101)
      |> response.set_body(reply.Upgrade(fn(socket) { run(socket, builder) }))
      |> response.set_header("upgrade", "websocket")
      |> response.set_header("connection", "Upgrade")
      |> response.set_header("sec-websocket-accept", accept)
  }
}

pub fn send_text(conn: Connection, text: String) -> Result(Nil, Nil) {
  send(conn.socket, TextFrame, bit_array.from_string(text))
}

pub fn send_binary(conn: Connection, data: BitArray) -> Result(Nil, Nil) {
  send(conn.socket, BinaryFrame, data)
}

/// The `sec-websocket-accept` value, or the response refusing the upgrade.
fn handshake(req: Request, trusted: List(String)) -> Result(String, Response) {
  let header = fn(name) {
    request.get_header(req, name) |> result.unwrap("") |> string.lowercase
  }
  let tokens = fn(name) {
    header(name) |> string.split(",") |> list.map(string.trim)
  }
  let key = request.get_header(req, "sec-websocket-key") |> result.unwrap("")
  let key_ok = case bit_array.base64_decode(key) {
    Ok(bytes) -> bit_array.byte_size(bytes) == 16
    Error(Nil) -> False
  }
  case
    req.method == http.Get,
    list.contains(tokens("upgrade"), "websocket"),
    list.contains(tokens("connection"), "upgrade"),
    header("sec-websocket-version") == "13",
    key_ok
  {
    True, True, True, True, True ->
      case origin.check(req, trusted) {
        Ok(Nil) -> Ok(frame.accept_key(key))
        Error(_) -> Error(reply.error(403, "cross-origin websocket rejected"))
      }
    True, True, True, False, _ ->
      Error(
        reply.error(426, "unsupported websocket version")
        |> response.set_header("sec-websocket-version", "13"),
      )
    _, _, _, _, _ -> Error(reply.bad_request("invalid websocket upgrade"))
  }
}

// --- The socket loop ---------------------------------------------------------

type Handlers(state, custom) {
  Handlers(
    on_init: fn(Connection) -> #(state, Option(Selector(custom))),
    on_message: fn(state, Connection, Message(custom)) -> Next(state),
    on_close: fn(state, CloseReason) -> Nil,
  )
}

type Event(custom) {
  Data(BitArray)
  SocketClosed
  Drain
  Tick
  User(custom)
  Ignore
}

type Loop(state, custom) {
  Loop(
    conn: Connection,
    handlers: Handlers(state, custom),
    state: state,
    selector: Selector(Event(custom)),
    buffer: BitArray,
    /// A fragmented message in progress: its opcode, pieces newest first,
    /// and size so far.
    partial: Option(#(Opcode, List(BitArray), Int)),
    /// When anything last arrived from the client, in monotonic ms.
    heard_at: Int,
    ticks: Subject(Nil),
    ping_interval: Option(Int),
    idle_timeout: Option(Int),
  )
}

fn run(socket: Socket, builder: Builder(state, custom)) -> Nil {
  let handlers = builder.handlers
  let conn = Connection(socket)
  let #(state, custom) = handlers.on_init(conn)
  let ticks = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select_record(atom.create("tcp"), 2, fn(message) {
      case decode.run(message, decode.at([2], decode.bit_array)) {
        Ok(data) -> Data(data)
        Error(_) -> Ignore
      }
    })
    |> process.select_record(atom.create("tcp_closed"), 1, fn(_) {
      SocketClosed
    })
    |> process.select_record(atom.create("tcp_error"), 2, fn(_) { SocketClosed })
    |> process.select_map(ticks, fn(_) { Tick })
    |> process.select_other(fn(message) {
      case is_drain(message) {
        True -> Drain
        False -> Ignore
      }
    })
  let selector = case custom {
    Some(custom) ->
      process.merge_selector(process.map_selector(custom, User), selector)
    None -> selector
  }
  let loop =
    Loop(
      conn:,
      handlers:,
      state:,
      selector:,
      buffer: <<>>,
      partial: None,
      heard_at: now_ms(),
      ticks:,
      ping_interval: option.map(builder.ping_interval, duration.to_milliseconds),
      idle_timeout: option.map(builder.idle_timeout, duration.to_milliseconds),
    )
  case tcp.drain_requested() {
    True -> close_by_server(loop, 1001, "", ShuttingDown)
    False -> {
      schedule(loop)
      arm(socket)
      wait(loop)
    }
  }
}

/// The next liveness check: a ping when one is due, otherwise when the idle
/// timeout could next pass.
fn schedule(loop: Loop(state, custom)) -> Nil {
  let delay = case loop.ping_interval, loop.idle_timeout {
    Some(ping), Some(idle) -> Some(int.min(ping, idle))
    Some(ping), None -> Some(ping)
    None, Some(idle) -> Some(idle)
    None, None -> None
  }
  case delay {
    Some(ms) -> {
      process.send_after(loop.ticks, int.max(ms, 1), Nil)
      Nil
    }
    None -> Nil
  }
}

fn wait(loop: Loop(state, custom)) -> Nil {
  case process.selector_receive_forever(loop.selector) {
    Data(data) -> {
      let loop =
        Loop(
          ..loop,
          buffer: bit_array.append(loop.buffer, data),
          heard_at: now_ms(),
        )
      case frames(loop) {
        Ok(loop) -> {
          arm(loop.conn.socket)
          wait(loop)
        }
        Error(Nil) -> Nil
      }
    }
    User(message) ->
      case deliver(loop, Custom(message)) {
        Ok(loop) -> wait(loop)
        Error(Nil) -> Nil
      }
    Tick -> {
      let silent = now_ms() - loop.heard_at
      case loop.idle_timeout {
        Some(idle) if silent >= idle -> close_by_server(loop, 1001, "", TimedOut)
        _ -> {
          case loop.ping_interval {
            Some(_) -> {
              let _ = send(loop.conn.socket, PingFrame, <<>>)
              Nil
            }
            None -> Nil
          }
          schedule(loop)
          wait(loop)
        }
      }
    }
    SocketClosed -> loop.handlers.on_close(loop.state, Disconnected)
    Drain -> close_by_server(loop, 1001, "", ShuttingDown)
    Ignore -> wait(loop)
  }
}

/// Handle every whole frame in the buffer. `Error` once the socket is done.
fn frames(loop: Loop(state, custom)) -> Result(Loop(state, custom), Nil) {
  case frame.parse(loop.buffer, max_message) {
    Error(Incomplete) -> Ok(loop)
    Error(Invalid(code:, ..)) ->
      Error(close_by_server(loop, code, "", ProtocolError(code)))
    Ok(#(received, rest)) ->
      handle(Loop(..loop, buffer: rest), received) |> result.try(frames)
  }
}

fn handle(
  loop: Loop(state, custom),
  received: Frame,
) -> Result(Loop(state, custom), Nil) {
  case received, loop.partial {
    Frame(opcode: PingFrame, payload:, ..), _ -> {
      let _ = send(loop.conn.socket, PongFrame, payload)
      Ok(loop)
    }
    Frame(opcode: PongFrame, ..), _ -> Ok(loop)
    Frame(opcode: CloseFrame, payload:, ..), _ -> {
      let code = frame.close_code(payload)
      let reason = close_reason(payload)
      // Echo the code, as the protocol asks; 1005 means none was given and
      // may not be sent, so a bare close is answered with 1000.
      let echoed = case code {
        1005 -> 1000
        code -> code
      }
      let _ =
        send(loop.conn.socket, CloseFrame, frame.close_payload(echoed, ""))
      loop.handlers.on_close(loop.state, ClientClosed(code:, reason:))
      Error(Nil)
    }
    Frame(opcode: TextFrame, fin: True, payload:), None
    | Frame(opcode: BinaryFrame, fin: True, payload:), None
    -> complete(loop, received.opcode, payload)
    Frame(opcode: TextFrame, fin: False, payload:), None
    | Frame(opcode: BinaryFrame, fin: False, payload:), None
    ->
      Ok(
        Loop(
          ..loop,
          partial: Some(#(
            received.opcode,
            [payload],
            bit_array.byte_size(payload),
          )),
        ),
      )
    Frame(opcode: Continuation, fin:, payload:), Some(#(opcode, pieces, size))
    -> {
      let size = size + bit_array.byte_size(payload)
      let pieces = [payload, ..pieces]
      case size > max_message, fin {
        True, _ -> Error(close_by_server(loop, 1009, "", ProtocolError(1009)))
        False, False -> Ok(Loop(..loop, partial: Some(#(opcode, pieces, size))))
        False, True ->
          complete(
            Loop(..loop, partial: None),
            opcode,
            bit_array.concat(list.reverse(pieces)),
          )
      }
    }
    // A new message mid-fragment, or a continuation of nothing.
    _, _ -> Error(close_by_server(loop, 1002, "", ProtocolError(1002)))
  }
}

fn complete(
  loop: Loop(state, custom),
  opcode: Opcode,
  payload: BitArray,
) -> Result(Loop(state, custom), Nil) {
  case opcode {
    TextFrame ->
      case bit_array.to_string(payload) {
        Ok(text) -> deliver(loop, Text(text))
        Error(Nil) ->
          Error(close_by_server(loop, 1007, "", ProtocolError(1007)))
      }
    _ -> deliver(loop, Binary(payload))
  }
}

fn deliver(
  loop: Loop(state, custom),
  message: Message(custom),
) -> Result(Loop(state, custom), Nil) {
  case loop.handlers.on_message(loop.state, loop.conn, message) {
    Continue(state) -> Ok(Loop(..loop, state:))
    Close(code:, reason:) -> {
      let code = sendable(code)
      let reason = truncate(reason, 123)
      Error(close_by_server(loop, code, reason, ServerClosed(code:, reason:)))
    }
  }
}

/// Send a close frame, wait briefly for the client's, run `on_close`, and
/// finish.
fn close_by_server(
  loop: Loop(state, custom),
  code: Int,
  reason: String,
  why: CloseReason,
) -> Nil {
  let payload = frame.close_payload(code, reason)
  case send(loop.conn.socket, CloseFrame, payload) {
    Ok(Nil) -> await_close(loop, loop.buffer, now_ms() + close_wait_ms)
    Error(Nil) -> Nil
  }
  loop.handlers.on_close(loop.state, why)
}

/// Read until the client's close frame arrives, the socket closes or the
/// deadline passes. Anything else the client sends meanwhile is dropped.
fn await_close(
  loop: Loop(state, custom),
  buffer: BitArray,
  deadline: Int,
) -> Nil {
  case frame.parse(buffer, max_message) {
    Ok(#(Frame(opcode: CloseFrame, ..), _)) -> Nil
    Ok(#(_, rest)) -> await_close(loop, rest, deadline)
    Error(Invalid(..)) -> Nil
    Error(Incomplete) -> {
      let left = deadline - now_ms()
      case left > 0 {
        False -> Nil
        True -> {
          arm(loop.conn.socket)
          case process.selector_receive(loop.selector, left) {
            Ok(Data(data)) ->
              await_close(loop, bit_array.append(buffer, data), deadline)
            Ok(SocketClosed) | Error(Nil) -> Nil
            Ok(_) -> await_close(loop, buffer, deadline)
          }
        }
      }
    }
  }
}

/// A code a server may send: 1000, the defined codes 1001 to 1014 other
/// than the reserved 1004, 1005 and 1006, or an application code from 3000
/// to 4999. Anything else becomes 1000.
fn sendable(code: Int) -> Int {
  case code {
    1004 | 1005 | 1006 -> 1000
    _ if code >= 1000 && code <= 1014 -> code
    _ if code >= 3000 && code <= 4999 -> code
    _ -> 1000
  }
}

/// The reason in a close frame's payload, after its two-byte code.
fn close_reason(payload: BitArray) -> String {
  case payload {
    <<_code:16, reason:bytes>> ->
      bit_array.to_string(reason) |> result.unwrap("")
    _ -> ""
  }
}

/// At most `limit` bytes of `text`, cut at a character boundary.
fn truncate(text: String, limit: Int) -> String {
  case string.byte_size(text) <= limit {
    True -> text
    False ->
      string.to_graphemes(text)
      |> list.fold(#("", 0), fn(acc, g) {
        let size = acc.1 + string.byte_size(g)
        case size <= limit {
          True -> #(acc.0 <> g, size)
          False -> #(acc.0, limit + 1)
        }
      })
      |> fn(pair) { pair.0 }
  }
}

fn now_ms() -> Int {
  monotonic_time(atom.create("millisecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

fn send(socket: Socket, opcode: Opcode, payload: BitArray) -> Result(Nil, Nil) {
  tcp.send(socket, bytes_tree.from_bit_array(frame.encode(opcode, payload)))
}

/// Deliver the next socket data to this process as a message.
@external(erlang, "gloss@http@server_ffi", "arm_raw")
fn arm(socket: Socket) -> Nil

@external(erlang, "gloss@http@server_ffi", "is_drain")
fn is_drain(message: Dynamic) -> Bool

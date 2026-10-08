//// WebSockets: upgrade a request, then exchange messages until either side
//// closes.
////
//// ```gleam
//// pub fn echo(req: Request, ctx: Context(State)) -> Response {
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
////   |> websocket.upgrade(req, ctx)
//// }
//// ```
////
//// After the `101 Switching Protocols` response the connection's process
//// runs the socket: it calls `on_message` for each text or binary message,
//// and for each message from the selector `on_init` returned (for
//// messages from other processes). It answers pings, reassembles
//// fragmented messages, and refuses messages over 16 MiB (see
//// `max_message`).
////
//// ## Sending
////
//// `send_text` and `send_binary` queue a message for the socket's writer
//// process, so a slow client never holds up the connection. A client that
//// falls more than 4 MiB behind (see `max_queue`) is dropped and `on_close`
//// is told `Backlogged`. Other processes send with `sender` and
//// `push_text`, or to every socket in a group with `join` and
//// `broadcast_text`:
////
//// ```gleam
//// on_init: fn(conn) {
////   websocket.join(conn, "thread:" <> int.to_string(id))
////   #(Nil, None)
//// }
//// // ...and anywhere else:
//// websocket.broadcast_text("thread:" <> int.to_string(id), html)
//// ```
////
//// ## Compression
////
//// When the client offers `permessage-deflate` (browsers do), messages of
//// 1 KiB or more are compressed, and compressed messages from the client
//// are inflated, still bounded by `max_message`. Turn it off with
//// `compress(builder, False)`.
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
//// for another code. When the server closes, it sends what is queued, then
//// waits up to a second for the client's close frame before dropping the
//// connection. `on_close` runs once, however the socket ends, and is told
//// why as a `CloseReason`.
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
////
//// ## Tracing
////
//// Each socket is a `websocket` span from source `gloss.http`, emitted when
//// it closes, a child of the upgrade request's span. Its meta has the
//// route, protocol, compression, messages and bytes each way, and the
//// close reason and code. A protocol error or a dropped backlogged client
//// marks the span failed.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import gloss/http/context.{type Context}
import gloss/http/reply.{type Request, type Response}
import gloss/http/traceparent
import gloss/internal/http_origin as origin
import gloss/internal/http_server_tcp.{type Socket} as tcp
import gloss/internal/http_websocket_frame.{
  type Frame, type Opcode, BinaryFrame, CloseFrame, Continuation, Frame,
  Incomplete, Invalid, PingFrame, PongFrame, TextFrame,
} as frame
import gloss/internal/runtime
import gloss/meta
import gloss/tracer.{type SpanContext, type Tracer}

/// The socket, for sending and joining groups. Use it from the
/// connection's own process, inside `on_init` and `on_message`; other
/// processes send with a `Sender`.
pub opaque type Connection {
  Connection(
    writer: Writer,
    pid: Pid,
    protocol: Option(String),
    deflate: Option(Zlib),
  )
}

/// Sends to a socket from any process. Get one with `sender`.
pub opaque type Sender {
  Sender(pid: Pid)
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
  /// 1002 for a malformed frame, 1007 for text that isn't UTF-8 or data
  /// that doesn't inflate, 1009 for a message over the size limit.
  ProtocolError(code: Int)
  /// The client read too slowly and fell more than `max_queue` bytes
  /// behind, so the connection was dropped.
  Backlogged
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
    protocols: List(String),
    compress: Bool,
    max_message: Int,
    max_queue: Int,
  )
}

/// How long a closing server waits for the client's close frame.
const close_wait_ms = 1000

/// Outgoing messages smaller than this aren't worth compressing.
const compress_from = 1024

/// A socket with these callbacks: ping every 30 seconds, close after 60
/// seconds of silence, refuse upgrades from other sites, compress when the
/// client can, accept messages up to 16 MiB and queue up to 4 MiB.
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
    protocols: [],
    compress: True,
    max_message: 16_777_216,
    max_queue: 4_194_304,
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

/// The subprotocols this socket speaks, e.g. `["graphql-transport-ws"]`.
/// The first one the client offers (in the client's order) is agreed and
/// sent back; read it with `protocol`. A client offering none of them is
/// still accepted, with no protocol, and may then close itself.
pub fn protocols(
  builder: Builder(state, custom),
  protocols: List(String),
) -> Builder(state, custom) {
  Builder(..builder, protocols:)
}

/// Whether to use `permessage-deflate` when the client offers it. On by
/// default.
pub fn compress(
  builder: Builder(state, custom),
  compress: Bool,
) -> Builder(state, custom) {
  Builder(..builder, compress:)
}

/// The largest message accepted from the client, in bytes once assembled
/// from its fragments and inflated. Larger ones close the socket with
/// 1009.
pub fn max_message(
  builder: Builder(state, custom),
  bytes: Int,
) -> Builder(state, custom) {
  Builder(..builder, max_message: bytes)
}

/// How many bytes may wait to be sent to a slow client before it is
/// dropped as `Backlogged`. A single message larger than this is still
/// sent when nothing else is waiting.
pub fn max_queue(
  builder: Builder(state, custom),
  bytes: Int,
) -> Builder(state, custom) {
  Builder(..builder, max_queue: bytes)
}

/// Answer `req` with `101 Switching Protocols` and run the socket, or
/// refuse it: `403` from another site, `426` for another protocol version,
/// `400` when it isn't a WebSocket upgrade.
pub fn upgrade(
  builder: Builder(state, custom),
  req: Request,
  ctx: Context(app),
) -> Response {
  case handshake(req, builder) {
    Error(response) -> response
    Ok(Accepted(key:, protocol:, deflate:)) -> {
      let observe =
        Observe(
          tracer: ctx.tracer,
          parent: traceparent.span_context(ctx.trace),
          route: ctx.route,
          protocol:,
          compressed: option.is_some(deflate),
        )
      let run = fn(socket) { run(socket, builder, protocol, deflate, observe) }
      response.new(101)
      |> response.set_body(reply.Upgrade(run))
      |> response.set_header("upgrade", "websocket")
      |> response.set_header("connection", "Upgrade")
      |> response.set_header("sec-websocket-accept", key)
      |> set_optional_header("sec-websocket-protocol", protocol)
      |> set_optional_header(
        "sec-websocket-extensions",
        option.map(deflate, fn(deflate) { deflate.1 }),
      )
    }
  }
}

fn set_optional_header(
  res: response.Response(body),
  name: String,
  value: Option(String),
) -> response.Response(body) {
  case value {
    Some(value) -> response.set_header(res, name, value)
    None -> res
  }
}

/// The subprotocol agreed with the client, if any.
pub fn protocol(conn: Connection) -> Option(String) {
  conn.protocol
}

/// Queue `text` for the client. `Error` once the socket has failed or the
/// client is too far behind; the socket then closes after this message.
pub fn send_text(conn: Connection, text: String) -> Result(Nil, Nil) {
  send_message(conn, TextFrame, bit_array.from_string(text))
}

pub fn send_binary(conn: Connection, data: BitArray) -> Result(Nil, Nil) {
  send_message(conn, BinaryFrame, data)
}

/// A handle other processes can send to this socket with.
pub fn sender(conn: Connection) -> Sender {
  Sender(conn.pid)
}

/// Send `text` to the socket from any process. Nothing happens once the
/// socket has closed.
pub fn push_text(sender: Sender, text: String) -> Nil {
  push(sender.pid, 1, bit_array.from_string(text))
}

pub fn push_binary(sender: Sender, data: BitArray) -> Nil {
  push(sender.pid, 2, data)
}

/// Add the socket to `group`, for `broadcast_text`. A socket leaves its
/// groups when it closes. Groups span every connected node.
pub fn join(conn: Connection, group: String) -> Nil {
  group_join(group, conn.pid)
}

pub fn leave(conn: Connection, group: String) -> Nil {
  group_leave(group, conn.pid)
}

/// Send `text` to every socket in `group`, from any process, and return how
/// many sockets that was.
pub fn broadcast_text(group: String, text: String) -> Int {
  broadcast(group, 1, bit_array.from_string(text))
}

pub fn broadcast_binary(group: String, data: BitArray) -> Int {
  broadcast(group, 2, data)
}

fn broadcast(group: String, kind: Int, payload: BitArray) -> Int {
  let members = group_members(group)
  list.each(members, push(_, kind, payload))
  list.length(members)
}

// --- The handshake -----------------------------------------------------------

type Accepted {
  /// `deflate` is the server's window bits and the extension header.
  Accepted(
    key: String,
    protocol: Option(String),
    deflate: Option(#(Int, String)),
  )
}

/// The upgrade's terms, or the response refusing it.
fn handshake(
  req: Request,
  builder: Builder(state, custom),
) -> Result(Accepted, Response) {
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
      case origin.check(req, builder.trusted) {
        Ok(Nil) ->
          Ok(
            Accepted(
              key: frame.accept_key(key),
              protocol: choose_protocol(req, builder.protocols),
              deflate: case builder.compress {
                True -> negotiate_deflate(req)
                False -> None
              },
            ),
          )
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

fn choose_protocol(req: Request, supported: List(String)) -> Option(String) {
  case supported {
    [] -> None
    _ ->
      request.get_header(req, "sec-websocket-protocol")
      |> result.unwrap("")
      |> string.split(",")
      |> list.map(string.trim)
      |> list.find(list.contains(supported, _))
      |> option.from_result
  }
}

/// The first `permessage-deflate` offer we can accept (RFC 7692), as the
/// window bits to compress with and the header answering it.
fn negotiate_deflate(req: Request) -> Option(#(Int, String)) {
  request.get_header(req, "sec-websocket-extensions")
  |> result.unwrap("")
  |> string.split(",")
  |> list.find_map(fn(offer) {
    case string.split(offer, ";") |> list.map(string.trim) {
      ["permessage-deflate", ..params] -> deflate_terms(params, 15, [])
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

fn deflate_terms(
  params: List(String),
  window: Int,
  seen: List(String),
) -> Result(#(Int, String), Nil) {
  case params {
    [] -> {
      let limit = case window {
        15 -> ""
        n -> "; server_max_window_bits=" <> int.to_string(n)
      }
      Ok(#(
        window,
        "permessage-deflate; server_no_context_takeover; client_no_context_takeover"
          <> limit,
      ))
    }
    [param, ..rest] -> {
      let #(name, value) = case string.split_once(param, "=") {
        Ok(#(name, value)) -> #(
          string.trim(name),
          Some(string.trim(value) |> string.replace("\"", "")),
        )
        Error(Nil) -> #(param, None)
      }
      use <- guard(list.contains(seen, name))
      let seen = [name, ..seen]
      case name, value {
        "server_no_context_takeover", None
        | "client_no_context_takeover", None
        | "client_max_window_bits", None
        -> deflate_terms(rest, window, seen)
        "client_max_window_bits", Some(bits) ->
          case int.parse(bits) {
            Ok(n) if n >= 8 && n <= 15 -> deflate_terms(rest, window, seen)
            _ -> Error(Nil)
          }
        // zlib can't make a raw deflate stream with an 8-bit window.
        "server_max_window_bits", Some(bits) ->
          case int.parse(bits) {
            Ok(n) if n >= 9 && n <= 15 -> deflate_terms(rest, n, seen)
            _ -> Error(Nil)
          }
        _, _ -> Error(Nil)
      }
    }
  }
}

fn guard(refuse: Bool, next: fn() -> Result(a, Nil)) -> Result(a, Nil) {
  case refuse {
    True -> Error(Nil)
    False -> next()
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

/// What the socket's span needs from the upgrade request.
type Observe {
  Observe(
    tracer: Tracer,
    parent: SpanContext,
    route: String,
    protocol: Option(String),
    compressed: Bool,
  )
}

type Event(custom) {
  Data(BitArray)
  SocketClosed
  Drain
  Tick
  Push(Opcode, BitArray)
  WriterFailed
  User(custom)
  Ignore
}

type Loop(state, custom) {
  Loop(
    conn: Connection,
    socket: Socket,
    handlers: Handlers(state, custom),
    state: state,
    selector: Selector(Event(custom)),
    buffer: BitArray,
    /// A fragmented message in progress: its opcode, whether it is
    /// compressed, pieces newest first, and size so far.
    partial: Option(Partial),
    /// When anything last arrived from the client, in monotonic ms.
    heard_at: Int,
    ticks: Subject(Nil),
    ping_interval: Option(Int),
    idle_timeout: Option(Int),
    max_message: Int,
    inflate: Option(Zlib),
    messages_in: Int,
    bytes_in: Int,
    observe: Observe,
    at: Timestamp,
    started: Int,
  )
}

type Partial {
  Partial(opcode: Opcode, compressed: Bool, pieces: List(BitArray), size: Int)
}

fn run(
  socket: Socket,
  builder: Builder(state, custom),
  protocol: Option(String),
  deflate: Option(#(Int, String)),
  observe: Observe,
) -> Nil {
  let at = timestamp.system_time()
  let started = now_ms()
  let handlers = builder.handlers
  let conn =
    Connection(
      writer: writer_start(socket, builder.max_queue),
      pid: process.self(),
      protocol:,
      deflate: option.map(deflate, fn(deflate) { deflate_open(deflate.0) }),
    )
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
    |> process.select_record(atom.create("gloss_ws_push"), 2, fn(message) {
      let push = {
        use kind <- decode.field(1, decode.int)
        use payload <- decode.field(2, decode.bit_array)
        decode.success(#(kind, payload))
      }
      case decode.run(message, push) {
        Ok(#(1, payload)) -> Push(TextFrame, payload)
        Ok(#(_, payload)) -> Push(BinaryFrame, payload)
        Error(_) -> Ignore
      }
    })
    |> process.select_map(ticks, fn(_) { Tick })
    |> process.select_other(fn(message) {
      case is_drain(message), is_writer_failed(message) {
        True, _ -> Drain
        _, True -> WriterFailed
        False, False -> Ignore
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
      socket:,
      handlers:,
      state:,
      selector:,
      buffer: <<>>,
      partial: None,
      heard_at: started,
      ticks:,
      ping_interval: option.map(builder.ping_interval, duration.to_milliseconds),
      idle_timeout: option.map(builder.idle_timeout, duration.to_milliseconds),
      max_message: builder.max_message,
      inflate: option.map(deflate, fn(_) { inflate_open() }),
      messages_in: 0,
      bytes_in: 0,
      observe:,
      at:,
      started:,
    )
  case tcp.drain_requested(), backlogged(loop) {
    True, _ -> close_by_server(loop, 1001, "", ShuttingDown)
    _, True -> finish(loop, Backlogged)
    False, False -> {
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
          arm(loop.socket)
          wait(loop)
        }
        Error(Nil) -> Nil
      }
    }
    User(message) -> after(deliver(loop, Custom(message)))
    Push(opcode, payload) -> {
      let _ = send_message(loop.conn, opcode, payload)
      after(Ok(loop))
    }
    Tick -> {
      let silent = now_ms() - loop.heard_at
      case loop.idle_timeout {
        Some(idle) if silent >= idle -> close_by_server(loop, 1001, "", TimedOut)
        _ -> {
          case loop.ping_interval {
            Some(_) -> {
              let _ = send_control(loop.conn, PingFrame, <<>>)
              Nil
            }
            None -> Nil
          }
          schedule(loop)
          wait(loop)
        }
      }
    }
    SocketClosed | WriterFailed -> finish(loop, Disconnected)
    Drain -> close_by_server(loop, 1001, "", ShuttingDown)
    Ignore -> wait(loop)
  }
}

/// Carry on after handling a message, unless sending fell behind.
fn after(result: Result(Loop(state, custom), Nil)) -> Nil {
  case result {
    Ok(loop) ->
      case backlogged(loop) {
        True -> finish(loop, Backlogged)
        False -> wait(loop)
      }
    Error(Nil) -> Nil
  }
}

/// Handle every whole frame in the buffer. `Error` once the socket is done.
fn frames(loop: Loop(state, custom)) -> Result(Loop(state, custom), Nil) {
  case
    frame.parse(loop.buffer, loop.max_message, option.is_some(loop.inflate))
  {
    Error(Incomplete) -> Ok(loop)
    Error(Invalid(code:, ..)) ->
      Error(close_by_server(loop, code, "", ProtocolError(code)))
    Ok(#(received, rest)) ->
      handle(Loop(..loop, buffer: rest), received)
      |> result.try(fn(loop) {
        case backlogged(loop) {
          True -> Error(finish(loop, Backlogged))
          False -> frames(loop)
        }
      })
  }
}

fn handle(
  loop: Loop(state, custom),
  received: Frame,
) -> Result(Loop(state, custom), Nil) {
  case received, loop.partial {
    Frame(opcode: PingFrame, payload:, ..), _ -> {
      let _ = send_control(loop.conn, PongFrame, payload)
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
        send_control(loop.conn, CloseFrame, frame.close_payload(echoed, ""))
      let _ = writer_flush(loop.conn.writer, close_wait_ms)
      Error(finish(loop, ClientClosed(code:, reason:)))
    }
    Frame(opcode: TextFrame, fin: True, payload:, compressed:), None
    | Frame(opcode: BinaryFrame, fin: True, payload:, compressed:), None
    -> complete(loop, received.opcode, compressed, payload)
    Frame(opcode: TextFrame, fin: False, payload:, compressed:), None
    | Frame(opcode: BinaryFrame, fin: False, payload:, compressed:), None
    ->
      Ok(
        Loop(
          ..loop,
          partial: Some(Partial(
            opcode: received.opcode,
            compressed:,
            pieces: [payload],
            size: bit_array.byte_size(payload),
          )),
        ),
      )
    Frame(opcode: Continuation, fin:, payload:, ..), Some(partial) -> {
      let size = partial.size + bit_array.byte_size(payload)
      let pieces = [payload, ..partial.pieces]
      case size > loop.max_message, fin {
        True, _ -> Error(close_by_server(loop, 1009, "", ProtocolError(1009)))
        False, False ->
          Ok(Loop(..loop, partial: Some(Partial(..partial, pieces:, size:))))
        False, True ->
          complete(
            Loop(..loop, partial: None),
            partial.opcode,
            partial.compressed,
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
  compressed: Bool,
  payload: BitArray,
) -> Result(Loop(state, custom), Nil) {
  let payload = case compressed, loop.inflate {
    True, Some(z) -> inflate(z, payload, loop.max_message)
    _, _ -> Ok(payload)
  }
  case payload {
    Error(code) -> Error(close_by_server(loop, code, "", ProtocolError(code)))
    Ok(payload) -> {
      let loop =
        Loop(
          ..loop,
          messages_in: loop.messages_in + 1,
          bytes_in: loop.bytes_in + bit_array.byte_size(payload),
        )
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

/// Send a close frame after what is queued, wait briefly for the client's,
/// and finish.
fn close_by_server(
  loop: Loop(state, custom),
  code: Int,
  reason: String,
  why: CloseReason,
) -> Nil {
  let payload = frame.close_payload(code, reason)
  let deadline = now_ms() + close_wait_ms
  case send_control(loop.conn, CloseFrame, payload) {
    Ok(Nil) ->
      case writer_flush(loop.conn.writer, close_wait_ms) {
        True -> await_close(loop, loop.buffer, deadline)
        False -> Nil
      }
    Error(Nil) -> Nil
  }
  finish(loop, why)
}

/// Read until the client's close frame arrives, the socket closes or the
/// deadline passes. Anything else the client sends meanwhile is dropped.
fn await_close(
  loop: Loop(state, custom),
  buffer: BitArray,
  deadline: Int,
) -> Nil {
  case frame.parse(buffer, loop.max_message, option.is_some(loop.inflate)) {
    Ok(#(Frame(opcode: CloseFrame, ..), _)) -> Nil
    Ok(#(_, rest)) -> await_close(loop, rest, deadline)
    Error(Invalid(..)) -> Nil
    Error(Incomplete) -> {
      let left = deadline - now_ms()
      case left > 0 {
        False -> Nil
        True -> {
          arm(loop.socket)
          case process.selector_receive(loop.selector, left) {
            Ok(Data(data)) ->
              await_close(loop, bit_array.append(buffer, data), deadline)
            Ok(SocketClosed) | Ok(WriterFailed) | Error(Nil) -> Nil
            Ok(_) -> await_close(loop, buffer, deadline)
          }
        }
      }
    }
  }
}

/// The socket is done: stop its writer, run `on_close`, emit its span.
fn finish(loop: Loop(state, custom), why: CloseReason) -> Nil {
  writer_stop(loop.conn.writer)
  loop.handlers.on_close(loop.state, why)
  let observe = loop.observe
  use <- tracer.emit(observe.tracer)
  let #(messages_out, bytes_out) = writer_stats(loop.conn.writer)
  let #(reason, code) = describe(why)
  let meta = [
    #("route", meta.String(observe.route)),
    #("compressed", meta.Bool(observe.compressed)),
    #("messages_in", meta.Int(loop.messages_in)),
    #("bytes_in", meta.Int(loop.bytes_in)),
    #("messages_out", meta.Int(messages_out)),
    #("bytes_out", meta.Int(bytes_out)),
    #("close_reason", meta.String(reason)),
  ]
  let meta = case code {
    Some(code) -> list.append(meta, [#("close_code", meta.Int(code))])
    None -> meta
  }
  let meta = case observe.protocol {
    Some(protocol) -> [#("protocol", meta.String(protocol)), ..meta]
    None -> meta
  }
  tracer.Span(
    source: "gloss.http",
    name: "websocket",
    at: loop.at,
    meta:,
    duration: duration.milliseconds(now_ms() - loop.started),
    error: case why {
      ProtocolError(code) -> Some("protocol error " <> int.to_string(code))
      Backlogged -> Some("client fell behind")
      _ -> None
    },
    trace: tracer.child(observe.parent),
    parent_span_id: Some(observe.parent.span_id),
  )
}

/// A close reason's name and code, for the span.
fn describe(why: CloseReason) -> #(String, Option(Int)) {
  case why {
    ClientClosed(code:, ..) -> #("client", Some(code))
    ServerClosed(code:, ..) -> #("server", Some(code))
    TimedOut -> #("timeout", Some(1001))
    ProtocolError(code) -> #("protocol_error", Some(code))
    Backlogged -> #("backlogged", None)
    ShuttingDown -> #("shutdown", Some(1001))
    Disconnected -> #("disconnected", None)
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
  runtime.monotonic_ms()
}

// --- Sending -----------------------------------------------------------------

/// A text or binary message, compressed when that was agreed and it is big
/// enough to be worth it.
fn send_message(
  conn: Connection,
  opcode: Opcode,
  payload: BitArray,
) -> Result(Nil, Nil) {
  let data = case conn.deflate {
    Some(z) if payload != <<>> ->
      case bit_array.byte_size(payload) >= compress_from {
        True -> frame.encode_compressed(opcode, deflate(z, payload))
        False -> frame.encode(opcode, payload)
      }
    _ -> frame.encode(opcode, payload)
  }
  writer_send(conn.writer, data, True, False) |> result.replace_error(Nil)
}

/// Pings, pongs and close frames, which skip the queue limit.
fn send_control(
  conn: Connection,
  opcode: Opcode,
  payload: BitArray,
) -> Result(Nil, Nil) {
  writer_send(conn.writer, frame.encode(opcode, payload), False, True)
  |> result.replace_error(Nil)
}

fn backlogged(loop: Loop(state, custom)) -> Bool {
  writer_backlogged(loop.conn.writer)
}

type Writer

type Zlib

@external(erlang, "gloss@http@websocket_ffi", "writer_start")
fn writer_start(socket: Socket, max_queue: Int) -> Writer

@external(erlang, "gloss@http@websocket_ffi", "writer_send")
fn writer_send(
  writer: Writer,
  data: BitArray,
  counted: Bool,
  bypass: Bool,
) -> Result(Nil, Dynamic)

@external(erlang, "gloss@http@websocket_ffi", "writer_flush")
fn writer_flush(writer: Writer, timeout: Int) -> Bool

@external(erlang, "gloss@http@websocket_ffi", "writer_backlogged")
fn writer_backlogged(writer: Writer) -> Bool

@external(erlang, "gloss@http@websocket_ffi", "writer_stats")
fn writer_stats(writer: Writer) -> #(Int, Int)

@external(erlang, "gloss@http@websocket_ffi", "writer_stop")
fn writer_stop(writer: Writer) -> Nil

@external(erlang, "gloss@http@websocket_ffi", "is_writer_failed")
fn is_writer_failed(message: Dynamic) -> Bool

@external(erlang, "gloss@http@websocket_ffi", "push")
fn push(pid: Pid, kind: Int, payload: BitArray) -> Nil

@external(erlang, "gloss@http@websocket_ffi", "group_join")
fn group_join(group: String, pid: Pid) -> Nil

@external(erlang, "gloss@http@websocket_ffi", "group_leave")
fn group_leave(group: String, pid: Pid) -> Nil

@external(erlang, "gloss@http@websocket_ffi", "group_members")
fn group_members(group: String) -> List(Pid)

@external(erlang, "gloss@http@websocket_ffi", "deflate_open")
fn deflate_open(window_bits: Int) -> Zlib

@external(erlang, "gloss@http@websocket_ffi", "deflate")
fn deflate(z: Zlib, data: BitArray) -> BitArray

@external(erlang, "gloss@http@websocket_ffi", "inflate_open")
fn inflate_open() -> Zlib

@external(erlang, "gloss@http@websocket_ffi", "inflate")
fn inflate(z: Zlib, data: BitArray, max: Int) -> Result(BitArray, Int)

/// Deliver the next socket data to this process as a message.
@external(erlang, "gloss@http@server_ffi", "arm_raw")
fn arm(socket: Socket) -> Nil

@external(erlang, "gloss@http@server_ffi", "is_drain")
fn is_drain(message: Dynamic) -> Bool

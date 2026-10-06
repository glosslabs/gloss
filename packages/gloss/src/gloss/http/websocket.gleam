//// WebSockets: upgrade a request, then exchange messages until either side
//// closes.
////
//// ```gleam
//// pub fn echo(req: Request, _ctx: Context(State)) -> Response {
////   websocket.upgrade(
////     req,
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
////     on_close: fn(_state) { Nil },
////   )
//// }
//// ```
////
//// After the `101 Switching Protocols` response the connection's process
//// runs the socket: it calls `on_message` for each text or binary message,
//// and for each message from the selector `on_init` returned (for
//// messages from other processes, e.g. a chat room). It answers pings,
//// reassembles fragmented messages, and refuses messages over 16 MiB.
//// `on_close` runs once, however the socket ends: the client closed it or
//// went away, a handler returned `stop()`, a protocol error, or the server
//// shutting down (which sends close code 1001, "going away").
////
//// A request that isn't a valid WebSocket upgrade gets `400`, or `426` for
//// an unsupported protocol version.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Selector}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloss/http/reply.{type Request, type Response}
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
  Stop
}

pub fn continue(state: state) -> Next(state) {
  Continue(state)
}

/// Close the socket normally (code 1000).
pub fn stop() -> Next(state) {
  Stop
}

/// The largest message accepted, assembled from all its fragments.
const max_message = 16_777_216

pub fn upgrade(
  req: Request,
  on_init on_init: fn(Connection) -> #(state, Option(Selector(custom))),
  on_message on_message: fn(state, Connection, Message(custom)) -> Next(state),
  on_close on_close: fn(state) -> Nil,
) -> Response {
  case handshake(req) {
    Error(response) -> response
    Ok(accept) ->
      response.new(101)
      |> response.set_body(
        reply.Upgrade(fn(socket) {
          run(socket, Handlers(on_init:, on_message:, on_close:))
        }),
      )
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
fn handshake(req: Request) -> Result(String, Response) {
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
    True, True, True, True, True -> Ok(frame.accept_key(key))
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
    on_close: fn(state) -> Nil,
  )
}

type Event(custom) {
  Data(BitArray)
  SocketClosed
  Drain
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
  )
}

fn run(socket: Socket, handlers: Handlers(state, custom)) -> Nil {
  let conn = Connection(socket)
  let #(state, custom) = handlers.on_init(conn)
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
    Loop(conn:, handlers:, state:, selector:, buffer: <<>>, partial: None)
  case tcp.drain_requested() {
    True -> close(loop, 1001)
    False -> {
      arm(socket)
      wait(loop)
    }
  }
}

fn wait(loop: Loop(state, custom)) -> Nil {
  case process.selector_receive_forever(loop.selector) {
    Data(data) ->
      case frames(Loop(..loop, buffer: bit_array.append(loop.buffer, data))) {
        Ok(loop) -> {
          arm(loop.conn.socket)
          wait(loop)
        }
        Error(Nil) -> Nil
      }
    User(message) ->
      case deliver(loop, Custom(message)) {
        Ok(loop) -> wait(loop)
        Error(Nil) -> Nil
      }
    SocketClosed -> loop.handlers.on_close(loop.state)
    Drain -> close(loop, 1001)
    Ignore -> wait(loop)
  }
}

/// Handle every whole frame in the buffer. `Error` once the socket is done.
fn frames(loop: Loop(state, custom)) -> Result(Loop(state, custom), Nil) {
  case frame.parse(loop.buffer, max_message) {
    Error(Incomplete) -> Ok(loop)
    Error(Invalid(code:, ..)) -> Error(close(loop, code))
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
      let code = case frame.close_code(payload) {
        1005 -> 1000
        code -> code
      }
      Error(close(loop, code))
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
        True, _ -> Error(close(loop, 1009))
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
    _, _ -> Error(close(loop, 1002))
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
        Error(Nil) -> Error(close(loop, 1007))
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
    Stop -> Error(close(loop, 1000))
  }
}

/// Send a close frame, run `on_close`, and finish.
fn close(loop: Loop(state, custom), code: Int) -> Nil {
  let _ = send(loop.conn.socket, CloseFrame, frame.close_payload(code, ""))
  loop.handlers.on_close(loop.state)
}

fn send(socket: Socket, opcode: Opcode, payload: BitArray) -> Result(Nil, Nil) {
  tcp.send(socket, bytes_tree.from_bit_array(frame.encode(opcode, payload)))
}

/// Deliver the next socket data to this process as a message.
@external(erlang, "gloss@http@server_ffi", "arm_raw")
fn arm(socket: Socket) -> Nil

@external(erlang, "gloss@http@server_ffi", "is_drain")
fn is_drain(message: Dynamic) -> Bool

//// One connection to Redis: a process that owns the socket, writes each
//// request as it arrives and hands replies back in order, so many callers
//// share it without waiting for each other (pipelining).
////
//// A pooled connection reconnects with backoff after the socket drops;
//// requests in flight then fail with `Lost`, and requests made while it is
//// down fail at once with `Down`. A dedicated connection (transactions
//// with WATCH, subscriptions) stops instead.

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gloss/redis/internal/resp.{type Value}

pub type Settings {
  Settings(
    host: String,
    port: Int,
    tls: Bool,
    verify: Bool,
    username: Option(String),
    password: Option(String),
    database: Int,
    /// Milliseconds, for connecting and the handshake.
    connect_timeout: Int,
    /// Reconnect after a drop, rather than stop.
    reconnect: Bool,
    /// Sent after every handshake, their replies not waited for.
    on_connect: List(List(BitArray)),
    /// Push mode, for subscriptions: every reply goes here.
    push: Option(fn(Value) -> Nil),
  )
}

pub type Failure {
  /// The connection dropped with the request in flight.
  Lost(reason: String)
  /// The connection is down: connecting failed, or it hasn't come back.
  Down(reason: String)
  TimedOut
  /// The connection process isn't running.
  Gone
}

pub opaque type Message {
  Request(data: BytesTree, replies: Int, reply_to: Subject(Answer))
  Socket(Dynamic)
  Reconnect
  Stop
}

type Answer =
  Result(List(Value), Failure)

/// Requests awaiting replies, oldest first: `front` in order, then `back`
/// newest first.
type Deque(a) {
  Deque(front: List(a), back: List(a))
}

fn deque_new() -> Deque(a) {
  Deque([], [])
}

fn deque_push_back(deque: Deque(a), item: a) -> Deque(a) {
  Deque(..deque, back: [item, ..deque.back])
}

fn deque_push_front(deque: Deque(a), item: a) -> Deque(a) {
  Deque(..deque, front: [item, ..deque.front])
}

fn deque_pop_front(deque: Deque(a)) -> Result(#(a, Deque(a)), Nil) {
  case deque.front, deque.back {
    [item, ..front], back -> Ok(#(item, Deque(front, back)))
    [], [] -> Error(Nil)
    [], back -> deque_pop_front(Deque(list.reverse(back), []))
  }
}

fn deque_to_list(deque: Deque(a)) -> List(a) {
  list.append(deque.front, list.reverse(deque.back))
}

type Pending {
  Pending(needed: Int, received: List(Value), reply_to: Subject(Answer))
}

type State {
  State(
    self: Subject(Message),
    settings: Settings,
    socket: Option(Socket),
    buffer: BitArray,
    pending: Deque(Pending),
    /// Why the connection is down, while it is.
    down: String,
    backoff: Int,
  )
}

pub type Socket

const min_backoff = 100

const max_backoff = 5000

/// Start a connection, linked to the caller. The first connection attempt
/// is made before this returns: a pooled connection starts anyway if it
/// fails, and keeps trying; a dedicated one fails to start.
pub fn start(settings: Settings) -> Result(Subject(Message), String) {
  actor.new_with_initialiser(settings.connect_timeout * 2 + 1000, fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_other(Socket)
    let state =
      State(
        self:,
        settings:,
        socket: None,
        buffer: <<>>,
        pending: deque_new(),
        down: "not connected yet",
        backoff: min_backoff,
      )
    case open(settings), settings.reconnect {
      Ok(socket), _ ->
        Ok(
          State(..state, socket: Some(socket))
          |> actor.initialised
          |> actor.selecting(selector)
          |> actor.returning(self),
        )
      Error(reason), True -> {
        process.send_after(self, min_backoff, Reconnect)
        Ok(
          State(..state, down: reason)
          |> actor.initialised
          |> actor.selecting(selector)
          |> actor.returning(self),
        )
      }
      Error(reason), False -> Error(reason)
    }
  })
  |> actor.on_message(on_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(error) {
    case error {
      actor.InitFailed(reason) -> reason
      actor.InitTimeout -> "timed out connecting"
      actor.InitExited(_) -> "the connection process exited"
    }
  })
}

/// Send `arguments` lists as one write and wait up to `timeout`
/// milliseconds for `replies` replies.
pub fn call(
  connection: Subject(Message),
  data: BytesTree,
  replies: Int,
  timeout: Int,
) -> Result(List(Value), Failure) {
  let reply_to = process.new_subject()
  case try_send(connection, Request(data:, replies:, reply_to:)) {
    False -> Error(Gone)
    True ->
      case process.receive(reply_to, timeout) {
        Ok(answer) -> answer
        Error(Nil) -> Error(TimedOut)
      }
  }
}

pub fn stop(connection: Subject(Message)) -> Nil {
  let _ = try_send(connection, Stop)
  Nil
}

fn on_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Request(data:, replies:, reply_to:) ->
      case state.socket {
        None -> {
          process.send(reply_to, Error(Down(state.down)))
          actor.continue(state)
        }
        Some(socket) ->
          case send(socket, data) {
            Ok(Nil) -> {
              let pending =
                deque_push_back(state.pending, Pending(replies, [], reply_to))
              actor.continue(State(..state, pending:))
            }
            Error(reason) -> {
              process.send(reply_to, Error(Lost(reason)))
              dropped(state, reason)
            }
          }
      }
    Socket(raw) ->
      case state.socket {
        None -> actor.continue(state)
        Some(socket) ->
          case socket_message(socket, raw) {
            Data(bytes) -> received(state, bytes)
            Closed -> dropped(state, "the server closed the connection")
            Failed(reason) -> dropped(state, reason)
            Other -> actor.continue(state)
          }
      }
    Reconnect ->
      case state.socket {
        Some(_) -> actor.continue(state)
        None ->
          case open(state.settings) {
            Ok(socket) ->
              actor.continue(
                State(..state, socket: Some(socket), backoff: min_backoff),
              )
            Error(reason) -> {
              process.send_after(state.self, state.backoff, Reconnect)
              actor.continue(
                State(
                  ..state,
                  down: reason,
                  backoff: int.min(state.backoff * 2, max_backoff),
                ),
              )
            }
          }
      }
    Stop -> {
      option.map(state.socket, close)
      fail_all(state.pending, Lost("the connection was closed"))
      actor.stop()
    }
  }
}

fn received(state: State, bytes: BitArray) -> actor.Next(State, Message) {
  case resp.parse_all(bit_array.append(state.buffer, bytes)) {
    Error(reason) -> dropped(state, "malformed reply: " <> reason)
    Ok(#(values, buffer)) -> {
      let state = list.fold(values, State(..state, buffer:), deliver)
      actor.continue(state)
    }
  }
}

fn deliver(state: State, value: Value) -> State {
  case state.settings.push {
    Some(push) -> {
      push(value)
      state
    }
    None ->
      case deque_pop_front(state.pending) {
        Error(Nil) -> state
        Ok(#(Pending(needed:, received:, reply_to:), rest)) -> {
          let received = [value, ..received]
          case needed - 1 {
            0 -> {
              process.send(reply_to, Ok(list.reverse(received)))
              State(..state, pending: rest)
            }
            needed ->
              State(
                ..state,
                pending: deque_push_front(
                  rest,
                  Pending(needed:, received:, reply_to:),
                ),
              )
          }
        }
      }
  }
}

/// The socket is gone: fail what was in flight, then reconnect or stop.
fn dropped(state: State, reason: String) -> actor.Next(State, Message) {
  option.map(state.socket, close)
  fail_all(state.pending, Lost(reason))
  let state =
    State(
      ..state,
      socket: None,
      buffer: <<>>,
      pending: deque_new(),
      down: reason,
    )
  case state.settings.reconnect {
    True -> {
      process.send_after(state.self, state.backoff, Reconnect)
      actor.continue(state)
    }
    False -> actor.stop()
  }
}

fn fail_all(pending: Deque(Pending), failure: Failure) -> Nil {
  deque_to_list(pending)
  |> list.each(fn(p) { process.send(p.reply_to, Error(failure)) })
}

/// Connect, authenticate and select the database, then turn the socket
/// active so replies arrive as messages.
fn open(settings: Settings) -> Result(Socket, String) {
  use socket <- result.try(connect(
    settings.host,
    settings.port,
    settings.tls,
    settings.verify,
    settings.connect_timeout,
  ))
  let handshake =
    list.flatten([
      case settings.password, settings.username {
        Some(password), Some(username) -> [
          [<<"AUTH">>, <<username:utf8>>, <<password:utf8>>],
        ]
        Some(password), None -> [[<<"AUTH">>, <<password:utf8>>]]
        None, _ -> []
      },
      case settings.database {
        0 -> []
        n -> [[<<"SELECT">>, <<int.to_string(n):utf8>>]]
      },
    ])
  let checked = case handshake {
    [] -> Ok(<<>>)
    _ -> {
      let data = list.map(handshake, resp.encode) |> bytes_tree.concat
      use Nil <- result.try(send(socket, data))
      use #(values, rest) <- result.try(read(
        socket,
        <<>>,
        list.length(handshake),
        settings.connect_timeout,
      ))
      case list.find(values, is_failure) {
        Ok(resp.Failure(message)) -> Error(message)
        _ -> Ok(rest)
      }
    }
  }
  case checked {
    Error(reason) -> {
      close(socket)
      Error(reason)
    }
    Ok(rest) -> {
      let setup = list.map(settings.on_connect, resp.encode)
      let sent = case setup {
        [] -> Ok(Nil)
        _ -> send(socket, bytes_tree.concat(setup))
      }
      case sent, rest {
        Ok(Nil), <<>> -> {
          activate(socket)
          Ok(socket)
        }
        Ok(Nil), _ -> {
          close(socket)
          Error("unexpected data after the handshake")
        }
        Error(reason), _ -> {
          close(socket)
          Error(reason)
        }
      }
    }
  }
}

fn is_failure(value: Value) -> Bool {
  case value {
    resp.Failure(_) -> True
    _ -> False
  }
}

/// Read until `count` replies have arrived.
fn read(
  socket: Socket,
  buffer: BitArray,
  count: Int,
  timeout: Int,
) -> Result(#(List(Value), BitArray), String) {
  use bytes <- result.try(recv(socket, timeout))
  let data = bit_array.append(buffer, bytes)
  use #(values, rest) <- result.try(resp.parse_all(data))
  case list.length(values) >= count {
    True -> Ok(#(values, rest))
    False -> read(socket, data, count, timeout)
  }
}

type SocketEvent {
  Data(BitArray)
  Closed
  Failed(String)
  Other
}

@external(erlang, "gloss@redis_ffi", "connect")
fn connect(
  host: String,
  port: Int,
  tls: Bool,
  verify: Bool,
  timeout: Int,
) -> Result(Socket, String)

@external(erlang, "gloss@redis_ffi", "send")
fn send(socket: Socket, data: BytesTree) -> Result(Nil, String)

@external(erlang, "gloss@redis_ffi", "recv")
fn recv(socket: Socket, timeout: Int) -> Result(BitArray, String)

@external(erlang, "gloss@redis_ffi", "activate")
fn activate(socket: Socket) -> Nil

@external(erlang, "gloss@redis_ffi", "close")
fn close(socket: Socket) -> Nil

@external(erlang, "gloss@redis_ffi", "socket_message")
fn socket_message(socket: Socket, message: Dynamic) -> SocketEvent

@external(erlang, "gloss@redis_ffi", "try_send")
fn try_send(subject: Subject(a), message: a) -> Bool

/// For error messages.
pub fn describe(failure: Failure) -> String {
  case failure {
    Lost(reason) -> "connection lost: " <> reason
    Down(reason) -> "connection down: " <> reason
    TimedOut -> "timed out"
    Gone -> "not running"
  }
  |> string.trim
}

//// The process behind `pg.start_listener`: one dedicated connection that
//// has issued `LISTEN` for every channel someone subscribed to, delivering
//// each notification to that channel's subscribers.
////
//// The socket stays in active-once mode, so notifications arrive as
//// messages. To run `LISTEN` or `UNLISTEN` the socket is switched back to
//// passive for the round trip. When the connection drops it is reopened
//// with backoff and every channel is listened to again.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Monitor, type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gloss/pg/internal/connection.{type Socket}
import gloss/pg/internal/protocol
import gloss/sql

pub type Message(n) {
  Listen(
    channel: String,
    subject: Subject(n),
    reply: Subject(Result(Nil, sql.Error)),
  )
  Unlisten(channel: String, subject: Subject(n))
  SocketMessage(Dynamic)
  Down(process.Down)
  Reconnect
  Stop
}

type Subscriber(n) {
  Subscriber(channel: String, subject: Subject(n), monitor: Option(Monitor))
}

type State(n) {
  State(
    inbox: Subject(Message(n)),
    settings: connection.Settings,
    make: fn(String, String, Int) -> n,
    socket: Option(Socket),
    /// Bytes received but not yet a whole message.
    buffer: BitArray,
    subscribers: List(Subscriber(n)),
    /// Milliseconds to wait before the next reconnect attempt.
    backoff: Int,
  )
}

const min_backoff = 500

const max_backoff = 30_000

/// Start a listener. `make` builds what subscribers receive from a
/// notification's channel, payload and sending backend's process id.
pub fn start(
  settings: connection.Settings,
  make: fn(String, String, Int) -> n,
  name: Option(Name(Message(n))),
) -> Result(actor.Started(Subject(Message(n))), actor.StartError) {
  let builder =
    actor.new_with_initialiser(settings.connect_timeout + 1000, fn(inbox) {
      case connection.connect(settings) {
        Error(error) -> Error(sql.describe(error))
        Ok(socket) -> {
          connection.activate(socket)
          let selector =
            process.new_selector()
            |> process.select(inbox)
            |> process.select_monitors(Down)
            |> process.select_other(SocketMessage)
          State(
            inbox:,
            settings:,
            make:,
            socket: Some(socket),
            buffer: <<>>,
            subscribers: [],
            backoff: min_backoff,
          )
          |> actor.initialised
          |> actor.selecting(selector)
          |> actor.returning(inbox)
          |> Ok
        }
      }
    })
    |> actor.on_message(handle)
  case name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
  |> actor.start
}

fn handle(
  state: State(n),
  message: Message(n),
) -> actor.Next(State(n), Message(n)) {
  case message {
    Listen(channel:, subject:, reply:) -> {
      let new = !listening(state, channel)
      let monitor =
        process.subject_owner(subject)
        |> result.map(process.monitor)
        |> option.from_result
      let subscriber = Subscriber(channel:, subject:, monitor:)
      let state = State(..state, subscribers: [subscriber, ..state.subscribers])
      case new {
        False -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        True -> {
          let #(state, result) = command(state, "LISTEN " <> ident(channel))
          process.send(reply, result)
          case result {
            Ok(Nil) -> actor.continue(state)
            Error(_) -> actor.continue(remove(state, fn(s) { s == subscriber }))
          }
        }
      }
    }

    Unlisten(channel:, subject:) ->
      remove(state, fn(s) { s.channel == channel && s.subject == subject })
      |> actor.continue

    Down(process.ProcessDown(monitor:, ..)) ->
      remove(state, fn(s) { s.monitor == Some(monitor) }) |> actor.continue

    Down(process.PortDown(..)) -> actor.continue(state)

    SocketMessage(raw) ->
      case state.socket {
        None -> actor.continue(state)
        Some(socket) ->
          case connection.socket_message(socket, raw) {
            connection.NotSocket -> actor.continue(state)
            connection.SocketClosed -> actor.continue(disconnected(state))
            connection.Data(data) ->
              case received(state, <<state.buffer:bits, data:bits>>) {
                Ok(state) -> {
                  connection.activate(socket)
                  actor.continue(state)
                }
                Error(Nil) -> actor.continue(disconnected(state))
              }
          }
      }

    Reconnect -> actor.continue(reconnect(state))

    Stop -> {
      case state.socket {
        Some(socket) -> connection.close_socket(socket)
        None -> Nil
      }
      actor.stop()
    }
  }
}

fn listening(state: State(n), channel: String) -> Bool {
  list.any(state.subscribers, fn(s) { s.channel == channel })
}

/// Drop the subscribers matching `drop`, and stop listening to channels
/// left with none.
fn remove(state: State(n), drop: fn(Subscriber(n)) -> Bool) -> State(n) {
  let #(dropped, kept) = list.partition(state.subscribers, drop)
  list.each(dropped, fn(s) { option.map(s.monitor, process.demonitor_process) })
  let state = State(..state, subscribers: kept)
  dropped
  |> list.map(fn(s) { s.channel })
  |> list.unique
  |> list.filter(fn(channel) { !listening(state, channel) })
  |> list.fold(state, fn(state, channel) {
    command(state, "UNLISTEN " <> ident(channel)).0
  })
}

/// Deliver the notifications in `buffer`, keeping any partial message.
fn received(state: State(n), buffer: BitArray) -> Result(State(n), Nil) {
  case connection.decode_all(buffer, []) {
    Ok(#(messages, rest)) -> {
      list.each(messages, deliver(state, _))
      Ok(State(..state, buffer: rest))
    }
    Error(_) -> Error(Nil)
  }
}

fn deliver(state: State(n), message: protocol.Message) -> Nil {
  case message {
    protocol.NotificationResponse(process_id:, channel:, payload:) ->
      list.each(state.subscribers, fn(s) {
        case s.channel == channel {
          True ->
            process.send(s.subject, state.make(channel, payload, process_id))
          False -> Nil
        }
      })
    _ -> Nil
  }
}

/// Run SQL on the listener's connection. While disconnected this does
/// nothing: reconnecting listens to every subscribed channel.
fn command(
  state: State(n),
  sql: String,
) -> #(State(n), Result(Nil, sql.Error)) {
  case state.socket {
    None -> #(state, Ok(Nil))
    Some(socket) -> {
      let buffer = <<state.buffer:bits, connection.deactivate(socket):bits>>
      let timeout = state.settings.connect_timeout
      case connection.command(socket, buffer, sql, timeout, deliver(state, _)) {
        Ok(rest) ->
          case received(state, rest) {
            Ok(state) -> {
              connection.activate(socket)
              #(state, Ok(Nil))
            }
            Error(Nil) -> #(disconnected(state), Ok(Nil))
          }
        // The server rejected the statement; the connection is fine.
        Error(sql.QueryFailed(..) as error) -> {
          connection.activate(socket)
          #(State(..state, buffer: <<>>), Error(error))
        }
        Error(error) -> #(disconnected(state), Error(error))
      }
    }
  }
}

fn disconnected(state: State(n)) -> State(n) {
  case state.socket {
    Some(socket) -> connection.close_socket(socket)
    None -> Nil
  }
  process.send_after(state.inbox, state.backoff, Reconnect)
  State(..state, socket: None, buffer: <<>>)
}

fn reconnect(state: State(n)) -> State(n) {
  case state.socket {
    Some(_) -> state
    None ->
      case connection.connect(state.settings) {
        Error(_) -> {
          let backoff = int.min(state.backoff * 2, max_backoff)
          process.send_after(state.inbox, backoff, Reconnect)
          State(..state, backoff:)
        }
        Ok(socket) -> {
          let state = State(..state, socket: Some(socket), backoff: min_backoff)
          let channels =
            list.map(state.subscribers, fn(s) { s.channel }) |> list.unique
          case channels {
            [] -> {
              connection.activate(socket)
              state
            }
            _ ->
              channels
              |> list.map(fn(channel) { "LISTEN " <> ident(channel) })
              |> string.join("; ")
              |> command(state, _)
              |> fn(outcome) { outcome.0 }
          }
        }
      }
  }
}

/// A quoted identifier: channel names are case-sensitive, as `pg_notify`
/// takes them.
fn ident(name: String) -> String {
  "\"" <> string.replace(name, "\"", "\"\"") <> "\""
}

//// Stores: what answers an application's storage messages, so its rules
//// can be kept apart from how its data is stored.
////
//// The application's core defines a store's messages, each carrying a
//// `Reply` for its answer, and sends them with `call`. An adapter answers
//// them from a database, and a test answers them from memory; the message
//// type is the only thing the two sides share.
////
//// ```gleam
//// // In the core: the port.
//// pub type Message {
////   Get(id: Int, reply: store.Reply(Option(User)))
////   Save(user: User, reply: store.Reply(Nil))
//// }
////
//// pub fn get(users: Store(Message), id: Int) -> Option(User) {
////   store.call(users, Get(id, _))
//// }
////
//// // In an adapter: answering from Postgres.
//// store.inline(fn(message) {
////   case message {
////     Get(id:, reply:) -> sql.optional(db, select(id)) |> store.reply(reply)
////     Save(user:, reply:) -> sql.exec(db, update(user)) |> store.reply(reply)
////   }
//// })
//// ```
////
//// ## Inline and serial stores
////
//// An `inline` store answers in the calling process, with no process of its
//// own: nothing is copied between processes and nothing needs starting. It
//// suits a store over a database, whose pool already runs statements
//// concurrently; the answering function captures what it needs, such as a
//// `sql.Db`. A `serial` store is a process that answers one message at a
//// time and keeps state between them, which suits a store held in memory.
////
//// ## Failure
////
//// Storage failing (the database being down) is rarely something the
//// caller can act on, so it is not part of a message's answer type: an
//// adapter's `sql.Error` is answered as `Unavailable(reason)` and `call`
//// panics with the reason. In a request handler that becomes a 500 that is
//// logged and traced. Business outcomes, such as an email already being
//// taken, belong in the answer itself.

import gleam/erlang/process.{type Name, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gloss/sql

/// Something that answers `message`s.
pub opaque type Store(message) {
  /// A process.
  Running(subject: Subject(message))
  /// A function run in the caller's process.
  Inline(answer: fn(message) -> Nil)
}

/// Storage could not answer, e.g. because the database is down.
pub type Unavailable {
  Unavailable(reason: String)
}

/// Where a store sends its answer to a message.
pub type Reply(a) =
  Subject(Result(a, Unavailable))

/// How to run a store process. Make one with `serial`, then `start` or
/// `supervised` it.
pub opaque type Builder(message) {
  Builder(
    start: fn(Option(Name(message))) ->
      Result(actor.Started(Subject(message)), actor.StartError),
    name: Option(Name(message)),
  )
}

/// A store that answers each message in the calling process, by running
/// `answer` there. It has no process, so there is nothing to start.
pub fn inline(answer: fn(message) -> Nil) -> Store(message) {
  Inline(answer)
}

/// A store that answers one message at a time, starting from `state` and
/// keeping the state each answer returns.
pub fn serial(
  state: state,
  answer: fn(state, message) -> state,
) -> Builder(message) {
  Builder(name: None, start: fn(name) {
    actor.new(state)
    |> actor.on_message(fn(state, message) {
      actor.continue(answer(state, message))
    })
    |> register(name)
    |> actor.start
  })
}

/// Register the store under `name`, so `from_name` reaches it across
/// restarts.
pub fn named(
  builder: Builder(message),
  name: Name(message),
) -> Builder(message) {
  Builder(..builder, name: Some(name))
}

/// Start the store, linked to the calling process.
pub fn start(
  builder: Builder(message),
) -> Result(Store(message), actor.StartError) {
  builder.start(builder.name)
  |> result.map(fn(started) { Running(started.data) })
}

/// A child for a supervision tree. Pair it with `named` and `from_name` to
/// reach the store from outside the tree.
pub fn supervised(
  builder: Builder(message),
) -> ChildSpecification(Store(message)) {
  supervision.worker(fn() {
    builder.start(builder.name)
    |> result.map(fn(started) {
      actor.Started(..started, data: Running(started.data))
    })
  })
}

/// The store registered under `name`. Usable before it starts.
pub fn from_name(name: Name(message)) -> Store(message) {
  Running(process.named_subject(name))
}

/// Send a message and wait up to ten seconds for its answer. Panics if the
/// store answers `Unavailable` or doesn't answer in time, or if a store
/// process isn't running.
pub fn call(store: Store(message), make: fn(Reply(a)) -> message) -> a {
  let answer = case store {
    Running(subject) -> process.call(subject, timeout, make)
    Inline(answer) -> {
      let reply = process.new_subject()
      answer(make(reply))
      case process.receive(reply, timeout) {
        Ok(answer) -> answer
        Error(Nil) -> panic as "store did not answer"
      }
    }
  }
  case answer {
    Ok(answer) -> answer
    Error(Unavailable(reason)) -> panic as { "store unavailable: " <> reason }
  }
}

const timeout = 10_000

/// Answer a message. A database error becomes `Unavailable`, so map the
/// errors that are business outcomes, such as a `sql.UniqueViolation`,
/// first. A store held in memory answers `Ok(value)`.
pub fn reply(result: Result(a, sql.Error), to reply: Reply(a)) -> Nil {
  process.send(
    reply,
    result.map_error(result, fn(error) { Unavailable(sql.describe(error)) }),
  )
}

fn register(
  builder: actor.Builder(state, message, return),
  name: Option(Name(message)),
) -> actor.Builder(state, message, return) {
  case name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
}

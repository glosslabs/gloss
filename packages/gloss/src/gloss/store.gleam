//// Stores: processes that answer storage messages, so the rules of an
//// application can be kept apart from how its data is stored.
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
//// store.concurrent(db, fn(db, message) {
////   case message {
////     Get(id:, reply:) ->
////       process.send(reply, sql.optional(db, select(id)) |> store.from_sql)
////     Save(user:, reply:) -> ...
////   }
//// })
//// |> store.start
//// ```
////
//// ## Concurrent and serial stores
////
//// `concurrent` answers each message in a process of its own, sharing an
//// immutable context such as a `sql.Db`, so a slow statement never holds
//// up the next. `serial` answers one message at a time and keeps state
//// between them, which suits a store held in memory.
////
//// ## Failure
////
//// Storage failing (the database being down) is rarely something the
//// caller can act on, so it is not part of a message's answer type: an
//// adapter answers `Error(Unavailable(reason))` and `call` panics with the
//// reason. In a request handler that becomes a 500 that is logged and
//// traced. Business outcomes, such as an email already being taken, belong
//// in the answer itself.
////
//// An adapter that panics while answering sends no reply, and the caller
//// waits the full `call` timeout before panicking itself, so adapters
//// should answer `Unavailable` rather than panic.

import gleam/erlang/process.{type Name, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gloss/sql

/// A running store that answers `message`s.
pub opaque type Store(message) {
  Store(subject: Subject(message))
}

/// Storage could not answer, e.g. because the database is down.
pub type Unavailable {
  Unavailable(reason: String)
}

/// Where a store sends its answer to a message.
pub type Reply(a) =
  Subject(Result(a, Unavailable))

/// How to run a store. Make one with `concurrent` or `serial`, then
/// `start` or `supervised` it.
pub opaque type Builder(message) {
  Builder(
    start: fn(Option(Name(message))) ->
      Result(actor.Started(Subject(message)), actor.StartError),
    name: Option(Name(message)),
  )
}

/// A store that answers each message in a new process, with `context`.
pub fn concurrent(
  context: context,
  answer: fn(context, message) -> Nil,
) -> Builder(message) {
  Builder(name: None, start: fn(name) {
    actor.new(context)
    |> actor.on_message(fn(context, message) {
      process.spawn_unlinked(fn() { answer(context, message) })
      actor.continue(context)
    })
    |> register(name)
    |> actor.start
  })
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
  |> result.map(fn(started) { Store(started.data) })
}

/// A child for a supervision tree. Pair it with `named` and `from_name` to
/// reach the store from outside the tree.
pub fn supervised(
  builder: Builder(message),
) -> ChildSpecification(Store(message)) {
  supervision.worker(fn() {
    builder.start(builder.name)
    |> result.map(fn(started) {
      actor.Started(..started, data: Store(started.data))
    })
  })
}

/// The store registered under `name`. Usable before it starts.
pub fn from_name(name: Name(message)) -> Store(message) {
  Store(process.named_subject(name))
}

/// Send a message and wait up to ten seconds for its answer. Panics if the
/// store answers `Unavailable`, doesn't answer in time, or isn't running.
pub fn call(store: Store(message), make: fn(Reply(a)) -> message) -> a {
  case process.call(store.subject, 10_000, make) {
    Ok(answer) -> answer
    Error(Unavailable(reason)) -> panic as { "store unavailable: " <> reason }
  }
}

/// A `gloss/sql` result as a store's answer: a database error becomes
/// `Unavailable`. Map the errors that are business outcomes, such as a
/// `sql.UniqueViolation`, before calling it.
pub fn from_sql(result: Result(a, sql.Error)) -> Result(a, Unavailable) {
  result.map_error(result, fn(error) { Unavailable(sql.describe(error)) })
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

//// An in-memory session store: an ETS table owned by one process.
////
//// ```gleam
//// let assert Ok(store) = memory.start()
//// let sessions = session.new(store)
//// ```
////
//// Request processes read and write the table directly, so the store adds
//// no message passing to a request. The owning process deletes expired
//// sessions once a minute. Sessions are lost when the node stops or the
//// owner exits. If the owner exits, a `Store` obtained from it keeps working
//// but stores nothing: loads find no session and saves are dropped.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import gloss/http/session.{type Store, Store}

type Table

type Message {
  Sweep
}

const sweep_interval_ms = 60_000

/// Start the store outside a supervision tree, linked to the caller.
pub fn start() -> Result(Store, actor.StartError) {
  start_actor() |> result.map(fn(started) { started.data })
}

/// A child for a supervision tree.
pub fn supervised() -> ChildSpecification(Store) {
  supervision.worker(start_actor)
}

fn start_actor() -> Result(actor.Started(Store), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self: Subject(Message)) {
    let table = new_table()
    process.send_after(self, sweep_interval_ms, Sweep)
    #(table, self)
    |> actor.initialised
    |> actor.returning(store(table))
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    let #(table, self) = state
    case message {
      Sweep -> {
        sweep(table, now_ms())
        process.send_after(self, sweep_interval_ms, Sweep)
        actor.continue(state)
      }
    }
  })
  |> actor.start
}

fn store(table: Table) -> Store {
  Store(
    load: fn(id, now) {
      case lookup(table, id) {
        Ok(#(data, expires_at)) ->
          case expires_at > to_ms(now) {
            True -> Ok(data)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    },
    save: fn(id, data, expires_at) {
      insert(table, id, data, to_ms(expires_at))
    },
    delete: fn(id) { delete(table, id) },
  )
}

fn to_ms(at: Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(at)
  seconds * 1000 + nanoseconds / 1_000_000
}

fn now_ms() -> Int {
  to_ms(timestamp.system_time())
}

@external(erlang, "gloss@http@session@memory_ffi", "new_table")
fn new_table() -> Table

@external(erlang, "gloss@http@session@memory_ffi", "lookup")
fn lookup(table: Table, id: String) -> Result(#(Dict(String, String), Int), Nil)

@external(erlang, "gloss@http@session@memory_ffi", "insert")
fn insert(
  table: Table,
  id: String,
  data: Dict(String, String),
  expires_at: Int,
) -> Nil

@external(erlang, "gloss@http@session@memory_ffi", "delete")
fn delete(table: Table, id: String) -> Nil

@external(erlang, "gloss@http@session@memory_ffi", "sweep")
fn sweep(table: Table, now: Int) -> Int

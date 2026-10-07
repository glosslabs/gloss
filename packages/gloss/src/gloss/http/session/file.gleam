//// A session store kept in a file, so sessions survive restarts.
////
//// ```gleam
//// let assert Ok(store) = file.start("data/sessions.dets")
//// let sessions = session.new(store)
//// ```
////
//// Sessions are held in memory, like `session/memory`, and every save and
//// delete is also written to a DETS file, which is read back when the store
//// starts. Loads never touch the file. The owning process deletes expired
//// sessions once a minute.
////
//// The file belongs to one node: servers behind a load balancer each have
//// their own sessions unless the balancer sends each client to the same
//// server. A file left by a crash is repaired when the store next opens it.
//// DETS files hold at most 2 GB.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import gloss/http/session.{type Store, Store}

type Tables

type Message {
  Sweep
}

const sweep_interval_ms = 60_000

/// Start the store outside a supervision tree, linked to the caller. The
/// file and its directory are created if missing.
pub fn start(path: String) -> Result(Store, actor.StartError) {
  start_actor(path) |> result.map(fn(started) { started.data })
}

/// A child for a supervision tree.
pub fn supervised(path: String) -> ChildSpecification(Store) {
  supervision.worker(fn() { start_actor(path) })
}

fn start_actor(path: String) -> Result(actor.Started(Store), actor.StartError) {
  // Opening a large or damaged file can take a while.
  actor.new_with_initialiser(60_000, fn(self: Subject(Message)) {
    case open(path, now_ms()) {
      Ok(tables) -> {
        process.send_after(self, sweep_interval_ms, Sweep)
        #(tables, self)
        |> actor.initialised
        |> actor.returning(store(tables))
        |> Ok
      }
      Error(reason) -> Error("cannot open " <> path <> ": " <> reason)
    }
  })
  |> actor.on_message(fn(state, message) {
    let #(tables, self) = state
    case message {
      Sweep -> {
        sweep(tables, now_ms())
        process.send_after(self, sweep_interval_ms, Sweep)
        actor.continue(state)
      }
    }
  })
  |> actor.start
}

fn store(tables: Tables) -> Store {
  Store(
    load: fn(id, now) {
      case lookup(tables, id) {
        Ok(#(data, expires_at)) ->
          case expires_at > to_ms(now) {
            True -> Ok(data)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    },
    save: fn(id, data, expires_at) {
      insert(tables, id, data, to_ms(expires_at))
    },
    delete: fn(id) { delete(tables, id) },
  )
}

fn to_ms(at: Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(at)
  seconds * 1000 + nanoseconds / 1_000_000
}

fn now_ms() -> Int {
  to_ms(timestamp.system_time())
}

@external(erlang, "gloss@http@session@file_ffi", "open")
fn open(path: String, now: Int) -> Result(Tables, String)

@external(erlang, "gloss@http@session@file_ffi", "lookup")
fn lookup(
  tables: Tables,
  id: String,
) -> Result(#(Dict(String, String), Int), Nil)

@external(erlang, "gloss@http@session@file_ffi", "insert")
fn insert(
  tables: Tables,
  id: String,
  data: Dict(String, String),
  expires_at: Int,
) -> Nil

@external(erlang, "gloss@http@session@file_ffi", "delete")
fn delete(tables: Tables, id: String) -> Nil

@external(erlang, "gloss@http@session@file_ffi", "sweep")
fn sweep(tables: Tables, now: Int) -> Nil

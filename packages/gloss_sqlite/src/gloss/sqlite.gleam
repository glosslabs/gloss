//// A SQLite driver for `gloss/sql/pool`, built on the esqlite NIF.
////
//// ```gleam
//// let assert Ok(db) =
////   pool.new(sqlite.driver(sqlite.file("data/app.db")))
////   |> pool.start
////
//// sql.query("select id, email from users where id = ?1")
//// |> sql.bind(sql.Int(id))
//// |> sql.returning(user)
//// |> pool.one(db, _)
//// ```
////
//// Placeholders are SQLite's numbered `?1`, `?2`, ..., which `sql.arg`
//// writes for you. Every connection turns on foreign keys and waits up to
//// five seconds for a lock rather than failing at once; file databases use
//// write-ahead logging, so readers don't block the writer. SQLite allows
//// one writer at a time, so a pool larger than a few connections only
//// helps readers.
////
//// ## Values
////
//// Integers, reals, text and blobs are stored as they are. Booleans are
//// stored as 0 and 1, timestamps as RFC 3339 text in UTC, dates as
//// `YYYY-MM-DD` and times as `HH:MM:SS`. Reading them back, a column
//// declared `BOOLEAN`, `TIMESTAMP` or `DATETIME`, `DATE`, `TIME` or `BLOB`
//// gives the matching Gleam value; other columns give what SQLite stored.
//// SQLite has no arrays. The same rules apply in the browser driver,
//// `gloss/sqlite_wasm`, so statements and decoders can be shared.
////
//// ## Timeouts
////
//// A statement that runs past the pool's query timeout is interrupted and
//// fails with `QueryTimeout`, and its connection is closed.

import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gloss/sql.{type Value}
import gloss/sql/internal/sqlite.{type Cell}
import gloss/sql/pool

/// Where the database lives.
pub opaque type Config {
  Config(filename: String, wal: Bool)
}

/// A database file, created if missing.
pub fn file(path: String) -> Config {
  Config(filename: path, wal: True)
}

/// A database held in memory, shared by the pool's connections and gone
/// once the last one closes. Each call makes a new, empty database.
pub fn memory() -> Config {
  Config(
    filename: "file:gloss_sqlite_"
      <> int.to_string(unique())
      <> "?mode=memory&cache=shared",
    wal: False,
  )
}

/// The driver to give `pool.new`.
pub fn driver(config: Config) -> pool.Driver {
  pool.Driver(name: "sqlite", dialect: sql.Sqlite, connect: fn() {
    connect(config)
  })
}

type Handle

fn connect(config: Config) -> Result(pool.Connection, sql.Error) {
  use handle <- result.try(
    open(config.filename)
    |> result.map_error(fn(e) { sql.ConnectionFailed(e.1) }),
  )
  let setup =
    "pragma foreign_keys = on; pragma busy_timeout = 5000;"
    <> case config.wal {
      True -> " pragma journal_mode = wal;"
      False -> ""
    }
  use _ <- result.try(
    ffi_script(handle, setup, 5000)
    |> result.map_error(fn(error) {
      close(handle)
      sql.ConnectionFailed(sql.describe(failure(error)))
    }),
  )
  Ok(pool.Connection(
    run: fn(text, args, timeout) { run(handle, text, args, timeout) },
    // BEGIN is a call into SQLite, not a round trip: nothing to save.
    run_after: option.None,
    script: fn(text, timeout) {
      ffi_script(handle, text, timeout) |> result.map_error(failure)
    },
    alive: fn() { alive(handle) },
    // The connection belongs to no process; the pool closes it.
    transfer: fn(_pid: process.Pid) { Nil },
    close: fn() { close(handle) },
    raw: dynamic.nil(),
  ))
}

fn run(
  handle: Handle,
  text: String,
  args: List(Value),
  timeout: Int,
) -> Result(sql.Outcome, sql.Error) {
  use cells <- result.try(list.try_map(args, sqlite.encode))
  use #(types, rows, affected) <- result.map(
    ffi_run(handle, text, cells, timeout) |> result.map_error(failure),
  )
  let columns = sqlite.columns(types)
  sql.Outcome(
    rows: list.map(rows, fn(row) { list.map2(row, columns, sqlite.read) }),
    affected:,
  )
}

/// A failure from the FFI: an SQLite error, or a call on a closed
/// connection.
type Failure

fn failure(failure: Failure) -> sql.Error {
  case decode_failure(failure) {
    Ok(#(code, message)) -> sqlite.error(code, message)
    Error(Nil) -> sql.ConnectionLost("the connection is closed")
  }
}

@external(erlang, "gloss@sqlite_ffi", "open")
fn open(filename: String) -> Result(Handle, #(Int, String))

@external(erlang, "gloss@sqlite_ffi", "run")
fn ffi_run(
  handle: Handle,
  sql: String,
  args: List(Cell),
  timeout: Int,
) -> Result(#(List(String), List(List(Cell)), Int), Failure)

@external(erlang, "gloss@sqlite_ffi", "script")
fn ffi_script(handle: Handle, sql: String, timeout: Int) -> Result(Nil, Failure)

@external(erlang, "gloss@sqlite_ffi", "close")
fn close(handle: Handle) -> Nil

@external(erlang, "gloss@sqlite_ffi", "alive")
fn alive(handle: Handle) -> Bool

@external(erlang, "gloss@sqlite_ffi", "unique")
fn unique() -> Int

@external(erlang, "gloss@sqlite_ffi", "failure")
fn decode_failure(failure: Failure) -> Result(#(Int, String), Nil)

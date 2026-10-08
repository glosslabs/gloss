//// PGlite, Postgres compiled to WebAssembly, for `gloss/sql`: a real
//// Postgres in the browser, or in Node, Deno and Bun, opened as an
//// `sql_async.Database`. Statements are Postgres SQL with `$1` placeholders,
//// and values are read exactly as `gloss/pg` reads them on the server, so
//// statements and decoders can be shared between the two.
////
//// ```gleam
//// use db <- promise.try_await(pglite.open(pglite.indexed_db("app")))
//// sql.query("select id, title from notes where id = $1")
//// |> sql.bind(sql.Int(id))
//// |> sql.returning(note_decoder())
//// |> sql_async.one(db, _)
//// ```
////
//// Install the JavaScript package alongside your app:
//// `npm install @electric-sql/pglite`.
////
//// ## Storage
////
//// | | |
//// |---|---|
//// | `memory()` | For the life of the page or process |
//// | `indexed_db(name)` | In the browser's IndexedDB, surviving reloads |
//// | `opfs(name)` | In the origin private file system; only inside a Web Worker |
//// | `directory(path)` | A directory on disk, in Node, Deno or Bun |
////
//// Sessions run in UTC with ISO dates, as `gloss/pg`'s do. PGlite is one
//// connection: calls run in turn, and a transaction holds the database
//// until it finishes. Statements run inside the WebAssembly module, so
//// there is no query timeout.

import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gloss/sql.{type Value}
import gloss/sql/internal/postgres
import gloss/sql_async.{type Database}

/// Where the database lives.
pub opaque type Config {
  Config(data_dir: String)
}

/// A database held in memory.
pub fn memory() -> Config {
  Config("memory://")
}

/// A database kept in the browser's IndexedDB under `name`.
pub fn indexed_db(name: String) -> Config {
  Config("idb://" <> name)
}

/// A database kept in the origin private file system under `name`. Only
/// inside a Web Worker.
pub fn opfs(name: String) -> Config {
  Config("opfs-ahp://" <> name)
}

/// A database kept in a directory on disk, in Node, Deno or Bun.
pub fn directory(path: String) -> Config {
  Config(path)
}

type Handle

/// Open the database, creating it if it doesn't exist.
pub fn open(config: Config) -> Promise(Result(Database, sql.Error)) {
  use opened <- promise.map(ffi_open(config.data_dir))
  use handle <- result.map(opened |> result.map_error(sql.ConnectionFailed))
  sql_async.database(
    name: "pglite",
    dialect: sql.Postgres,
    run: fn(text, args) { run(handle, text, args) },
    script: fn(text) {
      ffi_script(handle, text)
      |> promise.map(result.map_error(_, postgres.server_error))
    },
    close: fn() { ffi_close(handle) },
  )
}

fn run(
  handle: Handle,
  text: String,
  args: List(Value),
) -> Promise(Result(sql.Outcome, sql.Error)) {
  let args =
    list.map(args, fn(arg) {
      case arg {
        sql.Null -> None
        _ -> Some(postgres.to_text(arg))
      }
    })
  use ran <- promise.map(ffi_run(handle, text, args))
  use #(oids, rows, affected) <- result.map(
    ran |> result.map_error(postgres.server_error),
  )
  sql.Outcome(
    rows: list.map(rows, fn(row) {
      list.map2(row, oids, fn(cell, oid) {
        case cell {
          Some(text) -> postgres.decode(oid, <<text:utf8>>)
          None -> sql.Null
        }
      })
    }),
    affected:,
  )
}

@external(javascript, "./pglite_ffi.mjs", "open")
fn ffi_open(data_dir: String) -> Promise(Result(Handle, String))

@external(javascript, "./pglite_ffi.mjs", "run")
fn ffi_run(
  handle: Handle,
  sql: String,
  args: List(Option(String)),
) -> Promise(
  Result(#(List(Int), List(List(Option(String))), Int), List(#(String, String))),
)

@external(javascript, "./pglite_ffi.mjs", "script")
fn ffi_script(
  handle: Handle,
  sql: String,
) -> Promise(Result(Nil, List(#(String, String))))

@external(javascript, "./pglite_ffi.mjs", "close")
fn ffi_close(handle: Handle) -> Promise(Nil)

//// SQLite in the browser and other JavaScript runtimes, on the official
//// SQLite WebAssembly build (`@sqlite.org/sqlite-wasm`). It opens an
//// `async.Database` that runs the same `gloss/sql` statements the server
//// does.
////
//// ```gleam
//// use db <- promise.try_await(wasm.open(wasm.memory()))
//// use _ <- promise.try_await(async.script(db, schema))
//// sql.query("select id, title from notes order by id desc")
//// |> sql.returning(note_decoder())
//// |> async.all(db, _)
//// ```
////
//// Install the JavaScript package alongside your app:
//// `npm install @sqlite.org/sqlite-wasm`. Bundlers such as Vite serve its
//// `.wasm` file; see that package's README for setups without one.
////
//// ## Storage
////
//// `memory()` keeps the database for the life of the page. `opfs(name)`
//// keeps it in the browser's origin private file system, so it survives
//// reloads; that storage only works inside a Web Worker, so run the
//// database there and talk to it from the page. Browsers may clear stored
//// data under storage pressure unless the site asks for persistent storage
//// (`navigator.storage.persist()`).
////
//// ## Values
////
//// Values are stored and read exactly as by the BEAM driver, `gloss/sqlite`:
//// booleans as 0 and 1, timestamps as RFC 3339 text, dates and times as
//// text, and read back as Gleam values when the column is declared
//// `BOOLEAN`, `TIMESTAMP`, `DATE`, `TIME` or `BLOB`. Integers beyond 2^53
//// lose precision, as JavaScript numbers do. Statements run on the calling
//// thread, so there is no query timeout.

import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/result
import gloss/sql.{type Value}
import gloss/sql/async.{type Database}
import gloss/sql/internal/sqlite.{type Cell}

/// Where the database lives.
pub opaque type Config {
  Config(storage: Storage)
}

type Storage {
  Memory
  Opfs(name: String, directory: String)
}

/// A database held in memory for the life of the page.
pub fn memory() -> Config {
  Config(Memory)
}

/// A database kept in the origin private file system under `name`, which
/// survives reloads. Only inside a Web Worker.
pub fn opfs(name: String) -> Config {
  Config(Opfs(name: "/" <> name, directory: ".gloss-sqlite"))
}

type Handle

/// Open the database.
pub fn open(config: Config) -> Promise(Result(Database, sql.Error)) {
  let opened = case config.storage {
    Memory -> ffi_open("memory", "", "")
    Opfs(name:, directory:) -> ffi_open("opfs", name, directory)
  }
  use opened <- promise.map(opened)
  use handle <- result.map(opened |> result.map_error(sql.ConnectionFailed))
  async.database(
    name: "sqlite",
    placeholder: sqlite.placeholder,
    run: fn(text, args) { promise.resolve(run(handle, text, args)) },
    script: fn(text) {
      promise.resolve(ffi_script(handle, text) |> result.map_error(failure))
    },
    close: fn() { promise.resolve(ffi_close(handle)) },
  )
}

fn run(
  handle: Handle,
  text: String,
  args: List(Value),
) -> Result(sql.Outcome, sql.Error) {
  use cells <- result.try(list.try_map(args, sqlite.encode))
  use #(types, rows, affected) <- result.map(
    ffi_run(handle, text, cells) |> result.map_error(failure),
  )
  let declared = list.map(types, sqlite.declared)
  sql.Outcome(
    rows: list.map(rows, fn(row) {
      list.map2(row, declared, fn(cell, declared) {
        sqlite.decode(cell, declared)
      })
    }),
    affected:,
  )
}

fn failure(error: #(Int, String)) -> sql.Error {
  sqlite.error(error.0, error.1)
}

@external(javascript, "./wasm_ffi.mjs", "open")
fn ffi_open(
  kind: String,
  name: String,
  directory: String,
) -> Promise(Result(Handle, String))

@external(javascript, "./wasm_ffi.mjs", "run")
fn ffi_run(
  handle: Handle,
  sql: String,
  args: List(Cell),
) -> Result(#(List(String), List(List(Cell)), Int), #(Int, String))

@external(javascript, "./wasm_ffi.mjs", "script")
fn ffi_script(handle: Handle, sql: String) -> Result(Nil, #(Int, String))

@external(javascript, "./wasm_ffi.mjs", "close")
fn ffi_close(handle: Handle) -> Nil

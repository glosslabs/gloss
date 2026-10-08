//// Running `gloss/sql` statements in JavaScript, where databases answer
//// asynchronously, so every call returns a `Promise`. This is the browser's
//// counterpart to `gloss/sql/pool`: drivers such as `gloss/sqlite/wasm`
//// and `gloss/pglite` open a `Database`, and the same statements and
//// decoders the server uses run on it.
////
//// ```gleam
//// use db <- promise.try_await(wasm.open(wasm.memory()))
//// sql.query("select id, title from threads order by id desc limit ?1")
//// |> sql.bind(sql.Int(20))
//// |> sql.returning(thread_decoder())
//// |> async.all(db, _)
//// ```
////
//// A database is one connection. Calls run one at a time, in the order
//// they were made; while a transaction is open, other calls wait for it to
//// finish rather than run inside it.

import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option}
import gleam/result
import gloss/sql.{
  type Error, type Outcome, type Statement, type TransactionError, type Value,
}

type Queue

/// An open database, or the connection of a transaction.
pub opaque type Database {
  Database(
    name: String,
    dialect: sql.Dialect,
    run: fn(String, List(Value)) -> Promise(Result(Outcome, Error)),
    script: fn(String) -> Promise(Result(Nil, Error)),
    close: fn() -> Promise(Nil),
    queue: Queue,
    /// Inside a transaction: how many transactions deep. Its calls don't
    /// wait in the queue, which the transaction holds.
    depth: Int,
  )
}

/// A database from a driver's functions. For drivers: `run` runs one
/// statement with arguments, `script` runs SQL text that may hold several
/// statements, and `close` closes the database.
pub fn database(
  name name: String,
  dialect dialect: sql.Dialect,
  run run: fn(String, List(Value)) -> Promise(Result(Outcome, Error)),
  script script: fn(String) -> Promise(Result(Nil, Error)),
  close close: fn() -> Promise(Nil),
) -> Database {
  Database(name:, dialect:, run:, script:, close:, queue: new_queue(), depth: 0)
}

/// The driver's name, e.g. `"sqlite"`.
pub fn name(db: Database) -> String {
  db.name
}

/// Every row.
pub fn all(
  db: Database,
  statement: Statement(row),
) -> Promise(Result(List(row), Error)) {
  run(db, statement) |> promise.map(result.try(_, sql.all(_, statement)))
}

/// The only row. `NotFound` when there is none, `TooManyRows` when there
/// are several.
pub fn one(
  db: Database,
  statement: Statement(row),
) -> Promise(Result(row, Error)) {
  run(db, statement) |> promise.map(result.try(_, sql.one(_, statement)))
}

/// The only row, if there is one. `TooManyRows` when there are several.
pub fn optional(
  db: Database,
  statement: Statement(row),
) -> Promise(Result(Option(row), Error)) {
  run(db, statement) |> promise.map(result.try(_, sql.optional(_, statement)))
}

/// Run for the effect, returning how many rows were affected.
pub fn exec(
  db: Database,
  statement: Statement(row),
) -> Promise(Result(Int, Error)) {
  run(db, statement)
  |> promise.map(result.map(_, fn(outcome) { outcome.affected }))
}

/// Run SQL text that may hold several statements, such as a schema.
pub fn script(db: Database, sql: String) -> Promise(Result(Nil, Error)) {
  use <- exclusive(db)
  db.script(sql)
}

/// Close the database. Calls already made finish first.
pub fn close(db: Database) -> Promise(Nil) {
  use <- exclusive(db)
  db.close()
}

fn run(
  db: Database,
  statement: Statement(row),
) -> Promise(Result(Outcome, Error)) {
  let #(text, args) = sql.render(statement, db.dialect)
  use <- exclusive(db)
  db.run(text, args)
}

/// Run `task` in turn, unless this is a transaction's connection, which
/// already holds the turn.
fn exclusive(db: Database, task: fn() -> Promise(a)) -> Promise(a) {
  case db.depth {
    0 -> enqueue(db.queue, task)
    _ -> task()
  }
}

/// Run `body` in a transaction: commit when it resolves to `Ok`, roll back
/// when it resolves to `Error` or rejects. Run every statement of the body
/// on the `Database` it is given; other calls wait until it finishes. A
/// transaction inside a transaction is a savepoint.
///
/// ```gleam
/// async.transaction(db, fn(tx) {
///   use _ <- promise.try_await(async.exec(tx, debit))
///   async.exec(tx, credit)
/// })
/// ```
pub fn transaction(
  db: Database,
  body: fn(Database) -> Promise(Result(a, e)),
) -> Promise(Result(a, TransactionError(e))) {
  use <- exclusive(db)
  let #(begin, commit, rollback) = case db.depth {
    0 -> #("BEGIN", "COMMIT", "ROLLBACK")
    depth -> {
      let savepoint = "gloss_" <> int.to_string(depth)
      #(
        "SAVEPOINT " <> savepoint,
        "RELEASE SAVEPOINT " <> savepoint,
        "ROLLBACK TO SAVEPOINT " <> savepoint,
      )
    }
  }
  use begun <- promise.await(db.script(begin))
  case begun {
    Error(error) -> promise.resolve(Error(sql.TransactionFailed(error)))
    Ok(Nil) -> {
      let inner = Database(..db, depth: db.depth + 1)
      use outcome <- promise.await(settle(fn() { body(inner) }))
      case outcome {
        Ok(Ok(value)) -> {
          use committed <- promise.await(db.script(commit))
          case committed {
            Ok(Nil) -> promise.resolve(Ok(value))
            Error(error) -> {
              use _ <- promise.await(db.script(rollback))
              promise.resolve(Error(sql.TransactionFailed(error)))
            }
          }
        }
        Ok(Error(error)) -> {
          use _ <- promise.await(db.script(rollback))
          promise.resolve(Error(sql.RolledBack(error)))
        }
        Error(reason) -> {
          use _ <- promise.await(db.script(rollback))
          reject(reason)
        }
      }
    }
  }
}

type Reason

@external(javascript, "./async_ffi.mjs", "new_queue")
fn new_queue() -> Queue

@external(javascript, "./async_ffi.mjs", "enqueue")
fn enqueue(queue: Queue, task: fn() -> Promise(a)) -> Promise(a)

@external(javascript, "./async_ffi.mjs", "settle")
fn settle(task: fn() -> Promise(a)) -> Promise(Result(a, Reason))

@external(javascript, "./async_ffi.mjs", "reject")
fn reject(reason: Reason) -> Promise(a)

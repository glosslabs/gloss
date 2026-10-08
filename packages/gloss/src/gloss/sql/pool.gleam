//// Running SQL on the BEAM: a pool of connections from a `Driver`, such
//// as `gloss/pg` from the `gloss_pg` package, and the functions that run
//// `gloss/sql` statements on it.
////
//// ```gleam
//// let assert Ok(config) = pg.from_url("postgres://app:secret@localhost/app")
//// let assert Ok(db) =
////   pool.new(pg.driver(config))
////   |> pool.size(10)
////   |> pool.tracer(tracer)
////   |> pool.start
////
//// sql.query("select id, email from users where id = $1")
//// |> sql.bind(sql.Int(id))
//// |> sql.returning(user)
//// |> pool.one(db, _)
//// ```
////
//// Statements, values, errors and row decoding are in `gloss/sql` (the
//// `gloss_sql` package), which browser drivers share.
////
//// ## Connections
////
//// `start` runs a pool of up to `size` connections, opened as needed.
//// Each statement borrows one for its duration; a `transaction` keeps one
//// for the whole body. A process that dies while holding a connection has
//// it closed, never reused.
////
//// ## Tracing
////
//// Every statement is reported as a `tracer.Span` with source
//// `"gloss.sql"`, named after its `label` or else its first SQL keyword
//// (`"select"`, `"insert"`, ...), with `driver`, `sql` and `rows` in its
//// meta. Transactions are spans named `"transaction"` whose statements are
//// their children. Statements join the calling process's current span
//// (`tracer.current`), so under gloss/http they are part of the request's
//// trace; `child_of` names a parent explicitly.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gloss/internal/sql_pool.{type Lease}
import gloss/meta
import gloss/sql.{
  type Error, type Outcome, type Statement, type TransactionError, type Value,
}
import gloss/tracer.{type SpanContext, type Tracer}

// --- Drivers -----------------------------------------------------------------

/// What a database needs to provide. Applications get one from a driver
/// package, e.g. `pg.driver(config)`, and only pass it to `new`.
pub type Driver {
  Driver(
    /// Shown in traces, e.g. `"postgres"`.
    name: String,
    /// Open one connection. Called in a short-lived process; the connection
    /// is then handed to the pool with `transfer`.
    connect: fn() -> Result(Connection, Error),
    /// The placeholder for argument `n` (from 1): `$1` for Postgres, `?`
    /// for SQLite.
    placeholder: fn(Int) -> String,
  )
}

/// One open connection. Its functions are called from whichever process
/// has borrowed it, one at a time.
///
/// After `run` or `script` fails with `sql.QueryTimeout` or `sql.ConnectionLost`,
/// every later call must fail too, e.g. by closing the socket: replies to
/// the abandoned statement may still arrive, and inside a transaction the
/// connection keeps being used until the transaction ends.
pub type Connection {
  Connection(
    /// Run one statement with arguments, within `timeout` milliseconds.
    run: fn(String, List(Value), Int) -> Result(Outcome, Error),
    /// Run SQL text that may hold several statements and no arguments.
    script: fn(String, Int) -> Result(Nil, Error),
    /// Whether an idle connection still looks usable, without a round trip.
    alive: fn() -> Bool,
    /// Make `pid` the owner of the connection, so it lives as long as `pid`.
    transfer: fn(Pid) -> Nil,
    close: fn() -> Nil,
    /// The driver's own connection value, for driver-specific operations
    /// run through `borrow`, such as Postgres's `COPY`.
    raw: Dynamic,
  )
}

// --- The pool ----------------------------------------------------------------

type PoolMessage =
  sql_pool.Message(Connection, Error)

/// How to run a pool. Build one with `new` and the setters, then `start` or
/// `supervised` it.
pub opaque type Builder {
  Builder(
    driver: Driver,
    name: Name(PoolMessage),
    pool_size: Int,
    checkout_timeout: Duration,
    query_timeout: Duration,
    tracer: Tracer,
  )
}

/// A handle on a pool, or on the connection of a transaction.
pub opaque type Db {
  Db(
    pool: Subject(PoolMessage),
    driver: String,
    placeholder: fn(Int) -> String,
    checkout_timeout: Int,
    query_timeout: Int,
    tracer: Tracer,
    parent: Option(SpanContext),
    /// Inside a transaction: its connection and how many transactions deep.
    pinned: Option(#(Lease(Connection), Int)),
  )
}

pub type StartError {
  /// The pool process could not start, e.g. because a pool from the same
  /// builder is already running.
  StartFailed(reason: String)
}

const source = "gloss.sql"

/// A pool for `driver`.
///
/// Defaults: 10 connections, a 5 second checkout timeout, a 15 second query
/// timeout, no tracer handlers.
pub fn new(driver: Driver) -> Builder {
  Builder(
    driver:,
    name: process.new_name("gloss_sql"),
    pool_size: 10,
    checkout_timeout: duration.seconds(5),
    query_timeout: duration.seconds(15),
    tracer: tracer.new(),
  )
}

/// The most connections to keep open.
pub fn size(builder: Builder, size: Int) -> Builder {
  Builder(..builder, pool_size: int.max(size, 1))
}

/// How long a statement waits for a free connection.
pub fn checkout_timeout(builder: Builder, timeout: Duration) -> Builder {
  Builder(..builder, checkout_timeout: timeout)
}

/// How long a statement may run. A statement that runs past it fails with
/// `sql.QueryTimeout` and its connection is closed.
pub fn query_timeout(builder: Builder, timeout: Duration) -> Builder {
  Builder(..builder, query_timeout: timeout)
}

pub fn tracer(builder: Builder, tracer: Tracer) -> Builder {
  Builder(..builder, tracer:)
}

/// Start the pool, outside a supervision tree. It is linked to the calling
/// process. No connection is opened until a statement needs one.
pub fn start(builder: Builder) -> Result(Db, StartError) {
  case start_pool(builder) {
    Ok(_) -> Ok(db(builder))
    Error(error) -> Error(StartFailed(string.inspect(error)))
  }
}

/// A child for a supervision tree. Get the handle with `db`.
pub fn supervised(builder: Builder) -> ChildSpecification(Db) {
  supervision.worker(fn() {
    start_pool(builder)
    |> result.map(fn(started) { actor.Started(..started, data: db(builder)) })
  })
}

/// The handle on the pool `builder` starts. It can be made before the pool
/// starts and keeps working across restarts; statements fail with
/// `sql.Unavailable` while the pool is not running.
pub fn db(builder: Builder) -> Db {
  Db(
    pool: process.named_subject(builder.name),
    driver: builder.driver.name,
    placeholder: builder.driver.placeholder,
    checkout_timeout: duration.to_milliseconds(builder.checkout_timeout),
    query_timeout: duration.to_milliseconds(builder.query_timeout),
    tracer: builder.tracer,
    parent: None,
    pinned: None,
  )
}

/// Close every connection and stop the pool.
pub fn shutdown(db: Db) -> Nil {
  sql_pool.shutdown(db.pool)
}

/// Report this handle's statements as children of `parent`, e.g. the span
/// of the request they run for:
/// `pool.child_of(db, traceparent.span_context(ctx.trace))`.
pub fn child_of(db: Db, parent: SpanContext) -> Db {
  Db(..db, parent: Some(parent))
}

fn start_pool(
  builder: Builder,
) -> Result(actor.Started(Subject(PoolMessage)), actor.StartError) {
  let ops =
    sql_pool.Ops(
      connect: builder.driver.connect,
      alive: fn(connection: Connection) { connection.alive() },
      transfer: fn(connection: Connection, pid) { connection.transfer(pid) },
      close: fn(connection: Connection) { connection.close() },
      crashed: sql.ConnectionFailed,
    )
  sql_pool.start(ops, builder.pool_size, builder.name)
}

// --- Running statements ------------------------------------------------------

/// Every row.
pub fn all(db: Db, statement: Statement(row)) -> Result(List(row), Error) {
  use outcome <- result.try(run(db, statement))
  sql.all(outcome, statement)
}

/// The only row. `NotFound` when there is none, `TooManyRows` when there
/// are several.
pub fn one(db: Db, statement: Statement(row)) -> Result(row, Error) {
  use outcome <- result.try(run(db, statement))
  sql.one(outcome, statement)
}

/// The only row, if there is one. `TooManyRows` when there are several.
pub fn optional(
  db: Db,
  statement: Statement(row),
) -> Result(Option(row), Error) {
  use outcome <- result.try(run(db, statement))
  sql.optional(outcome, statement)
}

/// Run for the effect, returning how many rows were affected.
pub fn exec(db: Db, statement: Statement(row)) -> Result(Int, Error) {
  run(db, statement) |> result.map(fn(outcome) { outcome.affected })
}

/// Run SQL text that may hold several statements, such as a schema. It takes
/// no arguments.
pub fn script(db: Db, sql: String) -> Result(Nil, Error) {
  use <- traced(db, "script", fn() { describe_script(db, sql) }, fn(_) { 0 })
  use connection <- with_connection(db)
  connection.script(sql, db.query_timeout)
}

/// Run `work` on a connection: the transaction's, or one borrowed from the
/// pool for its duration. `work` also gets the query timeout in
/// milliseconds. This is for drivers that offer operations of their own
/// (`pg.copy_in`, for example), which find their connection in `raw`;
/// applications use the statement functions above. It is reported as a
/// span named `name`.
///
/// If `work` fails with `sql.QueryTimeout` or `sql.ConnectionLost`, or panics, the
/// connection is closed rather than reused.
pub fn borrow(
  db: Db,
  name: String,
  work: fn(Connection, Int) -> Result(a, Error),
) -> Result(a, Error) {
  let meta = fn() { [#("driver", meta.String(db.driver))] }
  use <- traced(db, name, meta, fn(_) { 0 })
  use connection <- with_connection(db)
  work(connection, db.query_timeout)
}

fn describe_script(db: Db, sql: String) -> meta.Meta {
  [#("driver", meta.String(db.driver)), #("sql", meta.String(sql))]
}

fn run(db: Db, statement: Statement(row)) -> Result(Outcome, Error) {
  let #(text, args) = sql.render(statement, db.placeholder)
  // Naming the statement costs string work, so only when it is traced.
  let name = case tracer.enabled(db.tracer) {
    True -> sql.name(statement, text)
    False -> ""
  }
  let meta = fn() {
    [
      #("driver", meta.String(db.driver)),
      #("sql", meta.String(text)),
      ..case sql.label_of(statement) {
        Some(label) -> [#("label", meta.String(label))]
        None -> []
      }
    ]
  }
  use <- traced(db, name, meta, fn(outcome: Outcome) { outcome.affected })
  use connection <- with_connection(db)
  connection.run(text, args, db.query_timeout)
}

// --- Transactions ------------------------------------------------------------

/// Run `body` in a transaction: commit when it returns `Ok`, roll back when
/// it returns `Error` or panics (the panic then continues). Run every
/// statement of the body on the `Db` it is given.
///
/// ```gleam
/// pool.transaction(db, fn(tx) {
///   use _ <- result.try(pool.exec(tx, debit))
///   pool.exec(tx, credit)
/// })
/// ```
///
/// A transaction inside a transaction is a savepoint: its rollback undoes
/// only its own statements.
pub fn transaction(
  db: Db,
  body: fn(Db) -> Result(a, e),
) -> Result(a, TransactionError(e)) {
  let meta = fn() { [#("driver", meta.String(db.driver))] }
  use db <- traced_transaction(db, meta)
  case db.pinned {
    Some(#(lease, depth)) -> {
      let #(result, _) = transact(db, lease, depth, body)
      result
    }
    None ->
      case
        sql_pool.checkout(
          db.pool,
          db.checkout_timeout,
          unavailable: sql.Unavailable,
          timed_out: sql.PoolTimeout,
        )
      {
        Error(error) -> Error(sql.TransactionFailed(error))
        Ok(lease) ->
          case rescue(fn() { transact(db, lease, 0, body) }) {
            Ok(#(result, reuse)) -> {
              sql_pool.checkin(db.pool, lease, reuse)
              result
            }
            Error(crash) -> {
              sql_pool.checkin(db.pool, lease, False)
              reraise(crash)
            }
          }
      }
  }
}

/// Run `body` between BEGIN and COMMIT, or a savepoint when `depth > 0`.
/// Also says whether the connection is fit to reuse.
fn transact(
  db: Db,
  lease: Lease(Connection),
  depth: Int,
  body: fn(Db) -> Result(a, e),
) -> #(Result(a, TransactionError(e)), Bool) {
  let connection = lease.connection
  let timeout = db.query_timeout
  let #(begin, commit, rollback) = case depth {
    0 -> #("BEGIN", "COMMIT", "ROLLBACK")
    _ -> {
      let savepoint = "gloss_" <> int.to_string(depth)
      #(
        "SAVEPOINT " <> savepoint,
        "RELEASE SAVEPOINT " <> savepoint,
        "ROLLBACK TO SAVEPOINT " <> savepoint,
      )
    }
  }
  let roll_back = fn() { connection.script(rollback, timeout) |> result.is_ok }

  case connection.script(begin, timeout) {
    Error(error) -> #(Error(sql.TransactionFailed(error)), reusable(error))
    Ok(Nil) -> {
      let inner = Db(..db, pinned: Some(#(lease, depth + 1)))
      case rescue(fn() { body(inner) }) {
        Ok(Ok(value)) ->
          case connection.script(commit, timeout) {
            Ok(Nil) -> #(Ok(value), True)
            Error(error) -> {
              let rolled_back = roll_back()
              #(
                Error(sql.TransactionFailed(error)),
                rolled_back && reusable(error),
              )
            }
          }
        Ok(Error(error)) -> #(Error(sql.RolledBack(error)), roll_back())
        Error(crash) -> {
          let _ = roll_back()
          reraise(crash)
        }
      }
    }
  }
}

fn traced_transaction(
  db: Db,
  meta: fn() -> meta.Meta,
  work: fn(Db) -> Result(a, TransactionError(e)),
) -> Result(a, TransactionError(e)) {
  use <- in_parent(db)
  tracer.span_result(
    db.tracer,
    source:,
    name: "transaction",
    meta: fn(result) {
      let outcome = case result {
        Ok(_) -> "committed"
        Error(sql.RolledBack(_)) -> "rolled_back"
        Error(sql.TransactionFailed(_)) -> "failed"
      }
      [#("outcome", meta.String(outcome)), ..meta()]
    },
    failure: fn(error) {
      case error {
        sql.TransactionFailed(error) -> Some(sql.describe(error))
        sql.RolledBack(_) -> None
      }
    },
    // The body's statements join the transaction's span, which is current.
    work: fn() { work(Db(..db, parent: None)) },
  )
}

// --- Connections and spans ---------------------------------------------------

/// Run `work` on the transaction's connection, or on one borrowed from the
/// pool for its duration.
fn with_connection(
  db: Db,
  work: fn(Connection) -> Result(a, Error),
) -> Result(a, Error) {
  case db.pinned {
    Some(#(lease, _)) -> work(lease.connection)
    None -> {
      use lease <- result.try(sql_pool.checkout(
        db.pool,
        db.checkout_timeout,
        unavailable: sql.Unavailable,
        timed_out: sql.PoolTimeout,
      ))
      case rescue(fn() { work(lease.connection) }) {
        Ok(result) -> {
          let reuse = case result {
            Ok(_) -> True
            Error(error) -> reusable(error)
          }
          sql_pool.checkin(db.pool, lease, reuse)
          result
        }
        Error(crash) -> {
          sql_pool.checkin(db.pool, lease, False)
          reraise(crash)
        }
      }
    }
  }
}

/// Whether a connection that produced `error` can serve another statement.
fn reusable(error: Error) -> Bool {
  case error {
    sql.ConnectionFailed(_) | sql.ConnectionLost(_) | sql.QueryTimeout -> False
    _ -> True
  }
}

fn traced(
  db: Db,
  name: String,
  meta: fn() -> meta.Meta,
  rows: fn(a) -> Int,
  work: fn() -> Result(a, Error),
) -> Result(a, Error) {
  use <- in_parent(db)
  tracer.span_result(
    db.tracer,
    source:,
    name:,
    meta: fn(result) {
      let rows = case result {
        Ok(value) -> rows(value)
        Error(_) -> 0
      }
      list.append(meta(), [#("rows", meta.Int(rows))])
    },
    failure: fn(error) { Some(sql.describe(error)) },
    work:,
  )
}

/// Run `work` with the parent named by `child_of`, if any, as the current
/// span; otherwise spans join the caller's current span.
fn in_parent(db: Db, work: fn() -> a) -> a {
  case db.parent {
    Some(parent) -> tracer.with_current(parent, work)
    None -> work()
  }
}

// --- FFI ---------------------------------------------------------------------

type Crash

@external(erlang, "gloss@sql_ffi", "rescue")
fn rescue(work: fn() -> a) -> Result(a, Crash)

@external(erlang, "gloss@sql_ffi", "reraise")
fn reraise(crash: Crash) -> a

//// A database layer shared by every gloss driver: one API for statements,
//// rows, transactions and pooling, with the database-specific work done by
//// a `Driver` such as `gloss/pg` from the `gloss_pg` package.
////
//// ```gleam
//// let assert Ok(config) = pg.from_url("postgres://app:secret@localhost/app")
//// let assert Ok(db) =
////   sql.new(pg.driver(config))
////   |> sql.pool_size(10)
////   |> sql.tracer(tracer)
////   |> sql.start
////
//// let user = {
////   use id <- decode.field(0, decode.int)
////   use email <- decode.field(1, decode.string)
////   decode.success(User(id:, email:))
//// }
////
//// sql.query("select id, email from users where id = $1")
//// |> sql.bind(sql.Int(id))
//// |> sql.returning(user)
//// |> sql.one(db, _)
//// ```
////
//// ## Statements
////
//// A `Statement` is SQL text, its arguments and a decoder for its rows.
//// Write the driver's own placeholders in `query` text and supply their
//// values with `bind`, in order. To build SQL from parts, `append` text and
//// add arguments with `arg`, which writes the placeholder for you; `when`
//// adds a part only when an optional value is present:
////
//// ```gleam
//// sql.query("select id, email from users where deleted_at is null")
//// |> sql.when(filter.status, fn(s, status) {
////   s |> sql.append(" and status = ") |> sql.arg(sql.Text(status))
//// })
//// |> sql.append(" order by id limit ")
//// |> sql.arg(sql.Int(limit))
//// ```
////
//// Placeholders written by `arg` are numbered after the arguments before
//// them, so `bind` and `arg` can be mixed. Only `query` and `append` text
//// reaches the database unescaped; never build it from user input.
////
//// ## Rows
////
//// Each row is decoded with `gleam/dynamic/decode`, addressing columns by
//// position: `decode.field(0, decode.int)`. Column values are Gleam values:
//// `NULL` is decoded with `decode.optional`, text with `decode.string`,
//// timestamps with `timestamp_decoder` and so on. Which database types map
//// to which values is up to the driver.
////
//// ## Connections
////
//// `start` runs a pool of up to `pool_size` connections, opened as needed.
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
//// their children. Use `child_of` to put a request's statements in the
//// request's trace.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import gleam/string_tree
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import gloss/internal/sql_pool.{type Lease}
import gloss/meta
import gloss/tracer.{type SpanContext, type Tracer}

// --- Values ------------------------------------------------------------------

/// A value sent to the database as a statement argument, or read back from
/// it by a driver.
pub type Value {
  Null
  Bool(Bool)
  Int(Int)
  Float(Float)
  Text(String)
  Bytes(BitArray)
  Timestamp(timestamp.Timestamp)
  Date(calendar.Date)
  Time(calendar.TimeOfDay)
  Array(List(Value))
}

/// `Null` for `None`, otherwise the value made by `of`:
/// `sql.nullable(user.bio, sql.Text)`.
pub fn nullable(value: Option(a), of to_value: fn(a) -> Value) -> Value {
  case value {
    Some(inner) -> to_value(inner)
    None -> Null
  }
}

// --- Errors ------------------------------------------------------------------

pub type Error {
  /// A connection could not be opened: unreachable, refused, or the
  /// credentials were rejected.
  ConnectionFailed(reason: String)
  /// The connection broke while in use.
  ConnectionLost(reason: String)
  /// The database rejected the statement. `code` is the driver's own error
  /// code, e.g. a Postgres SQLSTATE such as `"42P01"`.
  QueryFailed(code: String, message: String)
  UniqueViolation(constraint: String, message: String)
  ForeignKeyViolation(constraint: String, message: String)
  NotNullViolation(column: String, message: String)
  CheckViolation(constraint: String, message: String)
  /// The statement ran past the query timeout. Its connection is closed.
  QueryTimeout
  /// No connection became free within the checkout timeout.
  PoolTimeout
  /// The pool is not running.
  Unavailable
  /// `one` found no row.
  NotFound
  /// `one` or `optional` found more than one row.
  TooManyRows(count: Int)
  /// Row `row` (from 0) did not match the decoder.
  DecodeFailed(row: Int, errors: List(decode.DecodeError))
}

/// A one-line description of an error, for logs.
pub fn describe(error: Error) -> String {
  case error {
    ConnectionFailed(reason) -> "connection failed: " <> reason
    ConnectionLost(reason) -> "connection lost: " <> reason
    QueryFailed(code:, message:) -> message <> " (" <> code <> ")"
    UniqueViolation(constraint:, message:) ->
      "unique violation on " <> constraint <> ": " <> message
    ForeignKeyViolation(constraint:, message:) ->
      "foreign key violation on " <> constraint <> ": " <> message
    NotNullViolation(column:, message:) ->
      "not null violation on " <> column <> ": " <> message
    CheckViolation(constraint:, message:) ->
      "check violation on " <> constraint <> ": " <> message
    QueryTimeout -> "query timed out"
    PoolTimeout -> "timed out waiting for a connection"
    Unavailable -> "the pool is not running"
    NotFound -> "no rows"
    TooManyRows(count) -> "expected one row, got " <> int.to_string(count)
    DecodeFailed(row:, errors:) ->
      "row "
      <> int.to_string(row)
      <> " did not decode: "
      <> string.inspect(errors)
  }
}

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
/// After `run` or `script` fails with `QueryTimeout` or `ConnectionLost`,
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

/// What running a statement produced.
pub type Outcome {
  Outcome(
    /// Each row's column values, in column order.
    rows: List(List(Value)),
    /// Rows inserted, updated or deleted, or returned by a select.
    affected: Int,
  )
}

// --- Statements --------------------------------------------------------------

pub opaque type Statement(row) {
  Statement(
    /// Newest first.
    parts: List(Part),
    /// Newest first.
    args: List(Value),
    decoder: Decoder(row),
    label: Option(String),
  )
}

type Part {
  Sql(String)
  Placeholder(Int)
}

/// A statement from SQL text written with the driver's placeholders. Its
/// rows decode as `Dynamic` until `returning` gives it a decoder.
pub fn query(sql: String) -> Statement(Dynamic) {
  Statement(parts: [Sql(sql)], args: [], decoder: decode.dynamic, label: None)
}

/// Supply the value for the next placeholder written in the text.
pub fn bind(statement: Statement(row), value: Value) -> Statement(row) {
  Statement(..statement, args: [value, ..statement.args])
}

/// Add SQL text.
pub fn append(statement: Statement(row), sql: String) -> Statement(row) {
  Statement(..statement, parts: [Sql(sql), ..statement.parts])
}

/// Add a placeholder and the value for it.
pub fn arg(statement: Statement(row), value: Value) -> Statement(row) {
  let n = list.length(statement.args) + 1
  Statement(..statement, parts: [Placeholder(n), ..statement.parts], args: [
    value,
    ..statement.args
  ])
}

/// Apply `add` only when `value` is `Some`.
pub fn when(
  statement: Statement(row),
  value: Option(a),
  add: fn(Statement(row), a) -> Statement(row),
) -> Statement(row) {
  case value {
    Some(inner) -> add(statement, inner)
    None -> statement
  }
}

/// Decode each row with `decoder`.
pub fn returning(statement: Statement(a), decoder: Decoder(b)) -> Statement(b) {
  let Statement(parts:, args:, label:, ..) = statement
  Statement(parts:, args:, decoder:, label:)
}

/// Name the statement in traces, e.g. `"users.find_by_email"`.
pub fn label(statement: Statement(row), label: String) -> Statement(row) {
  Statement(..statement, label: Some(label))
}

/// The SQL text and arguments, with placeholders written by `placeholder`.
pub fn render(
  statement: Statement(row),
  placeholder: fn(Int) -> String,
) -> #(String, List(Value)) {
  let text =
    list.fold(statement.parts, [], fn(acc, part) {
      case part {
        Sql(sql) -> [sql, ..acc]
        Placeholder(n) -> [placeholder(n), ..acc]
      }
    })
    |> string_tree.from_strings
    |> string_tree.to_string
  #(text, list.reverse(statement.args))
}

// --- Decoders ----------------------------------------------------------------

/// Decodes a timestamp column.
pub fn timestamp_decoder() -> Decoder(timestamp.Timestamp) {
  decode.new_primitive_decoder("Timestamp", fn(data) {
    result.replace_error(ffi_timestamp(data), timestamp.unix_epoch)
  })
}

/// Decodes a date column.
pub fn date_decoder() -> Decoder(calendar.Date) {
  decode.new_primitive_decoder("Date", fn(data) {
    result.replace_error(
      ffi_date(data),
      calendar.Date(1970, calendar.January, 1),
    )
  })
}

/// Decodes a time-of-day column.
pub fn time_decoder() -> Decoder(calendar.TimeOfDay) {
  decode.new_primitive_decoder("TimeOfDay", fn(data) {
    result.replace_error(ffi_time_of_day(data), calendar.TimeOfDay(0, 0, 0, 0))
  })
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

pub type TransactionError(e) {
  /// The body returned `Error(e)` and the transaction was rolled back.
  RolledBack(e)
  /// Beginning or committing failed, or no connection was available.
  TransactionFailed(Error)
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
pub fn pool_size(builder: Builder, size: Int) -> Builder {
  Builder(..builder, pool_size: int.max(size, 1))
}

/// How long a statement waits for a free connection.
pub fn checkout_timeout(builder: Builder, timeout: Duration) -> Builder {
  Builder(..builder, checkout_timeout: timeout)
}

/// How long a statement may run. A statement that runs past it fails with
/// `QueryTimeout` and its connection is closed.
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
/// `Unavailable` while the pool is not running.
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
/// `sql.child_of(db, traceparent.span_context(ctx.trace))`.
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
      crashed: ConnectionFailed,
    )
  sql_pool.start(ops, builder.pool_size, builder.name)
}

// --- Running statements ------------------------------------------------------

/// Every row.
pub fn all(db: Db, statement: Statement(row)) -> Result(List(row), Error) {
  use outcome <- result.try(run(db, statement))
  decode_rows(outcome.rows, statement.decoder, 0, [])
}

/// The only row. `NotFound` when there is none, `TooManyRows` when there
/// are several.
pub fn one(db: Db, statement: Statement(row)) -> Result(row, Error) {
  use row <- result.try(optional(db, statement))
  option.to_result(row, NotFound)
}

/// The only row, if there is one. `TooManyRows` when there are several.
pub fn optional(
  db: Db,
  statement: Statement(row),
) -> Result(Option(row), Error) {
  use outcome <- result.try(run(db, statement))
  case outcome.rows {
    [] -> Ok(None)
    [row] -> decode_rows([row], statement.decoder, 0, []) |> result.map(first)
    rows -> Error(TooManyRows(list.length(rows)))
  }
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
/// If `work` fails with `QueryTimeout` or `ConnectionLost`, or panics, the
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
  let #(sql, args) = render(statement, db.placeholder)
  let name = option.lazy_unwrap(statement.label, fn() { operation(sql) })
  let meta = fn() {
    [
      #("driver", meta.String(db.driver)),
      #("sql", meta.String(sql)),
      ..case statement.label {
        Some(label) -> [#("label", meta.String(label))]
        None -> []
      }
    ]
  }
  use <- traced(db, name, meta, fn(outcome: Outcome) { outcome.affected })
  use connection <- with_connection(db)
  connection.run(sql, args, db.query_timeout)
}

fn first(rows: List(a)) -> Option(a) {
  case rows {
    [row, ..] -> Some(row)
    [] -> None
  }
}

fn decode_rows(
  rows: List(List(Value)),
  decoder: Decoder(row),
  index: Int,
  acc: List(row),
) -> Result(List(row), Error) {
  case rows {
    [] -> Ok(list.reverse(acc))
    [row, ..rest] ->
      case decode.run(to_row(row), decoder) {
        Ok(decoded) -> decode_rows(rest, decoder, index + 1, [decoded, ..acc])
        Error(errors) -> Error(DecodeFailed(row: index, errors:))
      }
  }
}

fn to_row(values: List(Value)) -> Dynamic {
  ffi_row(list.map(values, to_dynamic))
}

fn to_dynamic(value: Value) -> Dynamic {
  case value {
    Null -> dynamic.nil()
    Bool(b) -> dynamic.bool(b)
    Int(i) -> dynamic.int(i)
    Float(f) -> dynamic.float(f)
    Text(s) -> dynamic.string(s)
    Bytes(b) -> dynamic.bit_array(b)
    Timestamp(t) -> coerce(t)
    Date(d) -> coerce(d)
    Time(t) -> coerce(t)
    Array(values) -> dynamic.list(list.map(values, to_dynamic))
  }
}

/// The first word of the SQL, lower case: `"select"`, `"insert"`, ...
fn operation(sql: String) -> String {
  let sql = string.trim_start(sql)
  case string.split_once(sql, " ") {
    Ok(#(word, _)) -> string.lowercase(string.trim_end(word))
    Error(Nil) -> string.lowercase(sql)
  }
}

// --- Transactions ------------------------------------------------------------

/// Run `body` in a transaction: commit when it returns `Ok`, roll back when
/// it returns `Error` or panics (the panic then continues). Run every
/// statement of the body on the `Db` it is given.
///
/// ```gleam
/// sql.transaction(db, fn(tx) {
///   use _ <- result.try(sql.exec(tx, debit))
///   sql.exec(tx, credit)
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
          unavailable: Unavailable,
          timed_out: PoolTimeout,
        )
      {
        Error(error) -> Error(TransactionFailed(error))
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
    Error(error) -> #(Error(TransactionFailed(error)), reusable(error))
    Ok(Nil) -> {
      let inner = Db(..db, pinned: Some(#(lease, depth + 1)))
      case rescue(fn() { body(inner) }) {
        Ok(Ok(value)) ->
          case connection.script(commit, timeout) {
            Ok(Nil) -> #(Ok(value), True)
            Error(error) -> {
              let rolled_back = roll_back()
              #(Error(TransactionFailed(error)), rolled_back && reusable(error))
            }
          }
        Ok(Error(error)) -> #(Error(RolledBack(error)), roll_back())
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
  case tracer.enabled(db.tracer) {
    False -> work(db)
    True -> {
      let trace = span_context(db.parent)
      let at = timestamp.system_time()
      let started = monotonic_ns()
      let result = work(Db(..db, parent: Some(trace)))
      let #(outcome, error) = case result {
        Ok(_) -> #("committed", None)
        Error(RolledBack(_)) -> #("rolled_back", None)
        Error(TransactionFailed(error)) -> #("failed", Some(describe(error)))
      }
      tracer.emit(db.tracer, fn() {
        tracer.Span(
          source:,
          name: "transaction",
          at:,
          meta: [#("outcome", meta.String(outcome)), ..meta()],
          duration: duration.nanoseconds(monotonic_ns() - started),
          error:,
          trace:,
          parent_span_id: option.map(db.parent, fn(parent) { parent.span_id }),
        )
      })
      result
    }
  }
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
        unavailable: Unavailable,
        timed_out: PoolTimeout,
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
    ConnectionFailed(_) | ConnectionLost(_) | QueryTimeout -> False
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
  case tracer.enabled(db.tracer) {
    False -> work()
    True -> {
      let at = timestamp.system_time()
      let started = monotonic_ns()
      let result = work()
      let duration = duration.nanoseconds(monotonic_ns() - started)
      tracer.emit(db.tracer, fn() {
        let #(rows, error) = case result {
          Ok(value) -> #(rows(value), None)
          Error(error) -> #(0, Some(describe(error)))
        }
        tracer.Span(
          source:,
          name:,
          at:,
          meta: list.append(meta(), [#("rows", meta.Int(rows))]),
          duration:,
          error:,
          trace: span_context(db.parent),
          parent_span_id: option.map(db.parent, fn(parent) { parent.span_id }),
        )
      })
      result
    }
  }
}

fn span_context(parent: Option(SpanContext)) -> SpanContext {
  case parent {
    Some(parent) -> tracer.child(parent)
    None -> tracer.root()
  }
}

fn monotonic_ns() -> Int {
  monotonic_time(atom.create("nanosecond"))
}

// --- FFI ---------------------------------------------------------------------

type Crash

@external(erlang, "gloss@sql_ffi", "rescue")
fn rescue(work: fn() -> a) -> Result(a, Crash)

@external(erlang, "gloss@sql_ffi", "reraise")
fn reraise(crash: Crash) -> a

@external(erlang, "gloss@sql_ffi", "row")
fn ffi_row(cells: List(Dynamic)) -> Dynamic

@external(erlang, "gloss@sql_ffi", "coerce")
fn coerce(value: a) -> Dynamic

@external(erlang, "gloss@sql_ffi", "timestamp")
fn ffi_timestamp(data: Dynamic) -> Result(timestamp.Timestamp, Nil)

@external(erlang, "gloss@sql_ffi", "date")
fn ffi_date(data: Dynamic) -> Result(calendar.Date, Nil)

@external(erlang, "gloss@sql_ffi", "time_of_day")
fn ffi_time_of_day(data: Dynamic) -> Result(calendar.TimeOfDay, Nil)

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

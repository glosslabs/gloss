//// SQL statements, values, errors and row decoding, shared by every gloss
//// database driver, on the BEAM and in JavaScript. Statements built here
//// run with `gloss/sql/pool` on the BEAM (Postgres, MySQL, SQLite) or with a
//// browser driver such as `gloss/pglite`, so the same code can serve both.
////
//// ```gleam
//// let user = {
////   use id <- decode.field(0, decode.int)
////   use email <- decode.field(1, decode.string)
////   decode.success(User(id:, email:))
//// }
////
//// sql.query("select id, email from users where id = $1")
//// |> sql.bind(sql.Int(id))
//// |> sql.returning(user)
//// |> pool.one(db, _)
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
//// ## For drivers
////
//// A driver renders a statement with `render`, runs it, and hands back an
//// `Outcome`; `all`, `optional` and `one` decode it, and `name` is what to
//// call the statement in traces.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import gleam/time/calendar
import gleam/time/timestamp

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
  /// The pool or database is not running.
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
    Unavailable -> "the database is not available"
    NotFound -> "no rows"
    TooManyRows(count) -> "expected one row, got " <> int.to_string(count)
    DecodeFailed(row:, errors:) ->
      "row "
      <> int.to_string(row)
      <> " did not decode: "
      <> string.inspect(errors)
  }
}

// --- Transactions ------------------------------------------------------------

pub type TransactionError(e) {
  /// The body returned `Error(e)` and the transaction was rolled back.
  RolledBack(e)
  /// Beginning or committing failed, or no connection was available.
  TransactionFailed(Error)
}

/// The result of a transaction whose body fails with a `sql.Error`, with the
/// two kinds of failure merged:
///
/// ```gleam
/// pool.transaction(db, fn(tx) {
///   use id <- result.try(pool.one(tx, insert_order))
///   pool.exec(tx, insert_line(id))
/// })
/// |> sql.flatten
/// ```
pub fn flatten(result: Result(a, TransactionError(Error))) -> Result(a, Error) {
  case result {
    Ok(value) -> Ok(value)
    Error(RolledBack(error)) | Error(TransactionFailed(error)) -> Error(error)
  }
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

/// The SQL text and arguments, with placeholders written by `placeholder`:
/// `$1` for Postgres, `?` for SQLite and MySQL.
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

/// What to call a statement in traces: its `label`, or else the first word
/// of its rendered SQL in lower case (`"select"`, `"insert"`, ...).
pub fn name(statement: Statement(row), sql: String) -> String {
  option.lazy_unwrap(statement.label, fn() { operation(sql) })
}

/// The statement's label, if it has one.
pub fn label_of(statement: Statement(row)) -> Option(String) {
  statement.label
}

fn operation(sql: String) -> String {
  first_word(<<sql:utf8>>, <<>>) |> string.lowercase
}

/// The first run of characters after any leading whitespace.
fn first_word(bytes: BitArray, word: BitArray) -> String {
  case bytes, word {
    <<c, rest:bytes>>, <<>>
      if c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09
    -> first_word(rest, word)
    <<c, _:bytes>>, _ if c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09 ->
      bit_array_text(word)
    <<c, rest:bytes>>, _ -> first_word(rest, <<word:bits, c>>)
    _, _ -> bit_array_text(word)
  }
}

fn bit_array_text(bytes: BitArray) -> String {
  bit_array.to_string(bytes) |> result.unwrap("")
}

// --- Outcomes ----------------------------------------------------------------

/// What running a statement produced.
pub type Outcome {
  Outcome(
    /// Each row's column values, in column order.
    rows: List(List(Value)),
    /// Rows inserted, updated or deleted, or returned by a select.
    affected: Int,
  )
}

/// Every row of `outcome`, decoded with the statement's decoder.
pub fn all(
  outcome: Outcome,
  statement: Statement(row),
) -> Result(List(row), Error) {
  decode_rows(outcome.rows, statement.decoder, 0, [])
}

/// The only row of `outcome`, if there is one. `TooManyRows` when there are
/// several.
pub fn optional(
  outcome: Outcome,
  statement: Statement(row),
) -> Result(Option(row), Error) {
  case outcome.rows {
    [] -> Ok(None)
    [row] ->
      decode_rows([row], statement.decoder, 0, [])
      |> result.map(fn(rows) { list.first(rows) |> option.from_result })
    rows -> Error(TooManyRows(list.length(rows)))
  }
}

/// The only row of `outcome`. `NotFound` when there is none, `TooManyRows`
/// when there are several.
pub fn one(outcome: Outcome, statement: Statement(row)) -> Result(row, Error) {
  use row <- result.try(optional(outcome, statement))
  option.to_result(row, NotFound)
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

// --- FFI ---------------------------------------------------------------------

@external(erlang, "gloss_sql_ffi", "row")
@external(javascript, "./gloss_sql_ffi.mjs", "row")
fn ffi_row(cells: List(Dynamic)) -> Dynamic

@external(erlang, "gloss_sql_ffi", "coerce")
@external(javascript, "./gloss_sql_ffi.mjs", "coerce")
fn coerce(value: a) -> Dynamic

@external(erlang, "gloss_sql_ffi", "timestamp")
@external(javascript, "./gloss_sql_ffi.mjs", "timestamp")
fn ffi_timestamp(data: Dynamic) -> Result(timestamp.Timestamp, Nil)

@external(erlang, "gloss_sql_ffi", "date")
@external(javascript, "./gloss_sql_ffi.mjs", "date")
fn ffi_date(data: Dynamic) -> Result(calendar.Date, Nil)

@external(erlang, "gloss_sql_ffi", "time_of_day")
@external(javascript, "./gloss_sql_ffi.mjs", "time_of_day")
fn ffi_time_of_day(data: Dynamic) -> Result(calendar.TimeOfDay, Nil)

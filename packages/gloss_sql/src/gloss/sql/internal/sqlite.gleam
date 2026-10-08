//// How SQLite drivers convert values and errors, shared by `gloss/sqlite`
//// on the BEAM and `gloss/sqlite/wasm` in JavaScript so both behave alike.
////
//// SQLite stores integers, reals, text and blobs. Other values are kept as
//// text (timestamps as RFC 3339 in UTC, dates as `YYYY-MM-DD`, times as
//// `HH:MM:SS.sss`) or integers (booleans as 0 and 1), and read back as
//// Gleam values when the column's declared type names them: `BOOLEAN`,
//// `TIMESTAMP` or `DATETIME`, `DATE`, `TIME`, `BLOB`.

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gloss/sql

/// A value as SQLite stores it.
pub type Cell {
  Null
  Integer(Int)
  Real(Float)
  Text(String)
  Blob(BitArray)
  /// Text or a blob: the BEAM driver can't tell them apart, so the
  /// declared type and whether it is UTF-8 decide.
  Binary(BitArray)
}

/// The cell to bind for an argument. SQLite has no arrays.
pub fn encode(value: sql.Value) -> Result(Cell, sql.Error) {
  case value {
    sql.Null -> Ok(Null)
    sql.Bool(True) -> Ok(Integer(1))
    sql.Bool(False) -> Ok(Integer(0))
    sql.Int(i) -> Ok(Integer(i))
    sql.Float(f) -> Ok(Real(f))
    sql.Text(s) -> Ok(Text(s))
    sql.Bytes(b) -> Ok(Blob(b))
    sql.Timestamp(t) -> Ok(Text(timestamp.to_rfc3339(t, calendar.utc_offset)))
    sql.Date(d) -> Ok(Text(date_text(d)))
    sql.Time(t) -> Ok(Text(time_text(t)))
    sql.Array(_) ->
      Error(sql.QueryFailed(
        code: "unsupported",
        message: "SQLite has no array type; store arrays as JSON text",
      ))
  }
}

/// The value for a cell read from a column declared as `declared`.
pub fn decode(cell: Cell, declared: Option(String)) -> sql.Value {
  let declared = option.map(declared, string.uppercase) |> option.unwrap("")
  let kind = case declared {
    "DATE" -> "date"
    "TIME" -> "time"
    _ ->
      case
        string.contains(declared, "BOOL"),
        string.contains(declared, "TIMESTAMP")
        || string.contains(declared, "DATETIME"),
        string.contains(declared, "BLOB")
      {
        True, _, _ -> "bool"
        _, True, _ -> "timestamp"
        _, _, True -> "blob"
        _, _, _ -> ""
      }
  }
  case cell, kind {
    Null, _ -> sql.Null
    Integer(i), "bool" -> sql.Bool(i != 0)
    Integer(i), "timestamp" -> sql.Timestamp(timestamp.from_unix_seconds(i))
    Real(f), "timestamp" ->
      sql.Timestamp(timestamp.add(
        timestamp.unix_epoch,
        duration.nanoseconds(float.round(f *. 1_000_000_000.0)),
      ))
    Integer(i), _ -> sql.Int(i)
    Real(f), _ -> sql.Float(f)
    Blob(b), _ | Binary(b), "blob" -> sql.Bytes(b)
    Text(s), kind -> text_value(s, kind)
    Binary(b), kind ->
      case bit_array.to_string(b) {
        Ok(s) -> text_value(s, kind)
        Error(Nil) -> sql.Bytes(b)
      }
  }
}

fn text_value(text: String, kind: String) -> sql.Value {
  let parsed = case kind {
    "timestamp" -> parse_timestamp(text) |> result.map(sql.Timestamp)
    "date" -> parse_date(text) |> result.map(sql.Date)
    "time" -> parse_time(text) |> result.map(sql.Time)
    _ -> Error(Nil)
  }
  result.unwrap(parsed, sql.Text(text))
}

/// RFC 3339, or SQLite's own `YYYY-MM-DD HH:MM:SS[.SSS]` in UTC.
fn parse_timestamp(text: String) -> Result(timestamp.Timestamp, Nil) {
  case timestamp.parse_rfc3339(text) {
    Ok(t) -> Ok(t)
    Error(Nil) -> {
      let iso = string.replace(text, " ", "T")
      timestamp.parse_rfc3339(iso <> "Z")
    }
  }
}

fn parse_date(text: String) -> Result(calendar.Date, Nil) {
  case string.split(text, "-") {
    [y, m, d] -> {
      use y <- result.try(int.parse(y))
      use m <- result.try(int.parse(m) |> result.try(calendar.month_from_int))
      use d <- result.try(int.parse(d))
      Ok(calendar.Date(y, m, d))
    }
    _ -> Error(Nil)
  }
}

fn parse_time(text: String) -> Result(calendar.TimeOfDay, Nil) {
  let #(clock, fraction) = case string.split_once(text, ".") {
    Ok(#(clock, fraction)) -> #(clock, fraction)
    Error(Nil) -> #(text, "0")
  }
  case string.split(clock, ":") {
    [h, m, s] -> {
      use h <- result.try(int.parse(h))
      use m <- result.try(int.parse(m))
      use s <- result.try(int.parse(s))
      use nanos <- result.try(
        int.parse(string.pad_end(string.slice(fraction, 0, 9), 9, "0")),
      )
      Ok(calendar.TimeOfDay(h, m, s, nanos))
    }
    _ -> Error(Nil)
  }
}

fn date_text(date: calendar.Date) -> String {
  pad(date.year, 4)
  <> "-"
  <> pad(calendar.month_to_int(date.month), 2)
  <> "-"
  <> pad(date.day, 2)
}

fn time_text(time: calendar.TimeOfDay) -> String {
  pad(time.hours, 2)
  <> ":"
  <> pad(time.minutes, 2)
  <> ":"
  <> pad(time.seconds, 2)
  <> case time.nanoseconds {
    0 -> ""
    n -> "." <> pad(n, 9)
  }
}

fn pad(n: Int, width: Int) -> String {
  string.pad_start(int.to_string(n), width, "0")
}

/// The error for an SQLite extended result code and message.
pub fn error(code: Int, message: String) -> sql.Error {
  let subject = case string.split_once(message, "failed: ") {
    Ok(#(_, subject)) -> subject
    Error(Nil) -> ""
  }
  case code {
    // SQLITE_CONSTRAINT_UNIQUE, SQLITE_CONSTRAINT_PRIMARYKEY
    2067 | 1555 -> sql.UniqueViolation(constraint: subject, message:)
    // SQLITE_CONSTRAINT_FOREIGNKEY
    787 -> sql.ForeignKeyViolation(constraint: subject, message:)
    // SQLITE_CONSTRAINT_NOTNULL
    1299 -> sql.NotNullViolation(column: subject, message:)
    // SQLITE_CONSTRAINT_CHECK
    275 -> sql.CheckViolation(constraint: subject, message:)
    // SQLITE_INTERRUPT: the query timeout interrupted it.
    9 -> sql.QueryTimeout
    _ -> sql.QueryFailed(code: int.to_string(code), message:)
  }
}

/// The placeholder for argument `n`: SQLite's numbered `?N`.
pub fn placeholder(n: Int) -> String {
  "?" <> int.to_string(n)
}

/// `Some(declared)` unless it is empty.
pub fn declared(text: String) -> Option(String) {
  case text {
    "" -> None
    _ -> Some(text)
  }
}

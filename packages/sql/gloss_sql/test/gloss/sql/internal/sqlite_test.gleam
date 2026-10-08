import gleam/option.{None, Some}
import gleam/time/calendar
import gleam/time/timestamp
import gloss/sql
import gloss/sql/internal/sqlite.{Binary, Blob, Integer, Real, Text}

pub fn values_round_trip_through_declared_types_test() {
  let at =
    timestamp.from_unix_seconds_and_nanoseconds(1_700_000_000, 500_000_000)
  let day = calendar.Date(2026, calendar.October, 8)
  let time = calendar.TimeOfDay(9, 5, 7, 250_000_000)
  let round = fn(value, declared) {
    let assert Ok(cell) = sqlite.encode(value)
    sqlite.decode(cell, Some(declared))
  }
  assert round(sql.Bool(True), "BOOLEAN") == sql.Bool(True)
  assert round(sql.Bool(False), "boolean") == sql.Bool(False)
  assert round(sql.Timestamp(at), "TIMESTAMP") == sql.Timestamp(at)
  assert round(sql.Timestamp(at), "datetime") == sql.Timestamp(at)
  assert round(sql.Date(day), "DATE") == sql.Date(day)
  assert round(sql.Time(time), "TIME") == sql.Time(time)
  assert round(sql.Int(7), "INTEGER") == sql.Int(7)
  assert round(sql.Float(1.5), "REAL") == sql.Float(1.5)
  assert round(sql.Text("hi"), "TEXT") == sql.Text("hi")
  assert round(sql.Bytes(<<0, 255>>), "BLOB") == sql.Bytes(<<0, 255>>)
  assert round(sql.Null, "TEXT") == sql.Null
}

pub fn sqlite_own_timestamps_and_numbers_read_as_timestamps_test() {
  assert sqlite.decode(Text("2026-10-08 12:30:00"), Some("TIMESTAMP"))
    == sql.Timestamp(timestamp.from_unix_seconds(1_791_462_600))
  assert sqlite.decode(Integer(1_700_000_000), Some("DATETIME"))
    == sql.Timestamp(timestamp.from_unix_seconds(1_700_000_000))
  assert sqlite.decode(Real(1.5), Some("TIMESTAMP"))
    == sql.Timestamp(timestamp.from_unix_seconds_and_nanoseconds(1, 500_000_000))
  // Text that isn't a timestamp stays text.
  assert sqlite.decode(Text("soon"), Some("TIMESTAMP")) == sql.Text("soon")
}

pub fn undeclared_columns_keep_their_storage_class_test() {
  assert sqlite.decode(Integer(2), None) == sql.Int(2)
  assert sqlite.decode(Blob(<<1>>), None) == sql.Bytes(<<1>>)
  // The BEAM driver's binaries: text when UTF-8, unless declared BLOB.
  assert sqlite.decode(Binary(<<"ok":utf8>>), None) == sql.Text("ok")
  assert sqlite.decode(Binary(<<255>>), None) == sql.Bytes(<<255>>)
  assert sqlite.decode(Binary(<<"ok":utf8>>), Some("BLOB"))
    == sql.Bytes(<<"ok":utf8>>)
}

pub fn arrays_are_refused_test() {
  let assert Error(sql.QueryFailed(code: "unsupported", ..)) =
    sqlite.encode(sql.Array([]))
}

pub fn constraint_errors_are_named_test() {
  assert sqlite.error(2067, "UNIQUE constraint failed: users.email")
    == sql.UniqueViolation(
      constraint: "users.email",
      message: "UNIQUE constraint failed: users.email",
    )
  let assert sql.ForeignKeyViolation(..) =
    sqlite.error(787, "FOREIGN KEY constraint failed")
  assert sqlite.error(1299, "NOT NULL constraint failed: users.name")
    == sql.NotNullViolation(
      column: "users.name",
      message: "NOT NULL constraint failed: users.name",
    )
  let assert sql.CheckViolation(constraint: "positive", ..) =
    sqlite.error(275, "CHECK constraint failed: positive")
  assert sqlite.error(9, "interrupted") == sql.QueryTimeout
  assert sqlite.error(1, "no such table: x")
    == sql.QueryFailed(code: "1", message: "no such table: x")
}

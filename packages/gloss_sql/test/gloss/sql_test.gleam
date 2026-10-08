import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar
import gleam/time/timestamp
import gloss/sql

pub fn render_numbers_args_after_bound_ones_test() {
  let statement =
    sql.query("select * from t where a = $1")
    |> sql.bind(sql.Int(1))
    |> sql.when(Some("x"), fn(s, v) {
      s |> sql.append(" and b = ") |> sql.arg(sql.Text(v))
    })
    |> sql.when(None, fn(s, v) { s |> sql.append(" and c = ") |> sql.arg(v) })
    |> sql.append(" limit ")
    |> sql.arg(sql.Int(10))
  assert sql.render(statement, sql.Postgres)
    == #("select * from t where a = $1 and b = $2 limit $3", [
      sql.Int(1),
      sql.Text("x"),
      sql.Int(10),
    ])
  // Placeholders written by `arg` follow the driver's style.
  let question =
    sql.query("select * from t where a = ?")
    |> sql.bind(sql.Int(1))
    |> sql.append(" and b = ")
    |> sql.arg(sql.Text("x"))
  assert sql.render(question, sql.Mysql).0
    == "select * from t where a = ? and b = ?"
  assert sql.render(question, sql.Sqlite).0
    == "select * from t where a = ? and b = ?2"
}

pub fn identifiers_are_quoted_for_the_dialect_test() {
  let statement =
    sql.query("select ")
    |> sql.identifier("users.email")
    |> sql.append(" from ")
    |> sql.identifier("we\"ird")
  assert sql.render(statement, sql.Postgres).0
    == "select \"users\".\"email\" from \"we\"\"ird\""
  assert sql.render(statement, sql.Sqlite).0
    == "select \"users\".\"email\" from \"we\"\"ird\""
  assert sql.render(statement, sql.Mysql).0
    == "select `users`.`email` from `we\"ird`"
}

pub fn names_come_from_labels_or_the_first_keyword_test() {
  assert sql.name(sql.query(""), "  SELECT 1") == "select"
  assert sql.name(sql.query("") |> sql.label("users.get"), "select 1")
    == "users.get"
  assert sql.label_of(sql.query("")) == None
}

pub fn rows_decode_by_position_beyond_eight_columns_test() {
  let wide = list.map([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], sql.Int)
  let statement =
    sql.query("")
    |> sql.returning({
      use first <- decode.field(0, decode.int)
      use tenth <- decode.field(9, decode.int)
      decode.success(#(first, tenth))
    })
  assert sql.all(sql.Outcome(rows: [wide, wide], affected: 2), statement)
    == Ok([#(0, 9), #(0, 9)])
}

pub fn values_decode_as_gleam_values_test() {
  let at = timestamp.from_unix_seconds(1_700_000_000)
  let day = calendar.Date(2026, calendar.October, 8)
  let time = calendar.TimeOfDay(12, 30, 0, 0)
  let statement =
    sql.query("")
    |> sql.returning({
      use null <- decode.field(0, decode.optional(decode.int))
      use flag <- decode.field(1, decode.bool)
      use ratio <- decode.field(2, decode.float)
      use name <- decode.field(3, decode.string)
      use bytes <- decode.field(4, decode.bit_array)
      use when <- decode.field(5, sql.timestamp_decoder())
      use date <- decode.field(6, sql.date_decoder())
      use clock <- decode.field(7, sql.time_decoder())
      use tags <- decode.field(8, decode.list(decode.string))
      decode.success(#(null, flag, ratio, name, bytes, when, date, clock, tags))
    })
  let row = [
    sql.Null,
    sql.Bool(True),
    sql.Float(1.5),
    sql.Text("ada"),
    sql.Bytes(<<1, 2>>),
    sql.Timestamp(at),
    sql.Date(day),
    sql.Time(time),
    sql.Array([sql.Text("a"), sql.Text("b")]),
  ]
  assert sql.one(sql.Outcome(rows: [row], affected: 1), statement)
    == Ok(#(None, True, 1.5, "ada", <<1, 2>>, at, day, time, ["a", "b"]))
}

pub fn one_and_optional_count_rows_test() {
  let statement = sql.query("") |> sql.returning(decode.at([0], decode.int))
  let outcome = fn(rows) { sql.Outcome(rows:, affected: list.length(rows)) }
  assert sql.one(outcome([]), statement) == Error(sql.NotFound)
  assert sql.optional(outcome([]), statement) == Ok(None)
  assert sql.optional(outcome([[sql.Int(1)]]), statement) == Ok(Some(1))
  assert sql.one(outcome([[sql.Int(1)], [sql.Int(2)]]), statement)
    == Error(sql.TooManyRows(2))
}

pub fn decode_failures_name_the_row_test() {
  let statement = sql.query("") |> sql.returning(decode.at([0], decode.int))
  let assert Error(sql.DecodeFailed(row: 1, ..)) =
    sql.all(
      sql.Outcome(rows: [[sql.Int(1)], [sql.Text("x")]], affected: 2),
      statement,
    )
  // Text is not mistaken for a timestamp.
  let stamp =
    sql.query("") |> sql.returning(decode.at([0], sql.timestamp_decoder()))
  let assert Error(sql.DecodeFailed(row: 0, ..)) =
    sql.one(sql.Outcome(rows: [[sql.Text("2026")]], affected: 1), stamp)
}

pub fn flatten_merges_transaction_errors_test() {
  assert sql.flatten(Ok(1)) == Ok(1)
  assert sql.flatten(Error(sql.RolledBack(sql.NotFound))) == Error(sql.NotFound)
  assert sql.flatten(Error(sql.TransactionFailed(sql.Unavailable)))
    == Error(sql.Unavailable)
}

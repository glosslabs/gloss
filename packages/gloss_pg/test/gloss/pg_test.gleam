//// Tests against a real Postgres. They run only when GLOSS_TEST_PG_URL is
//// set, e.g. `postgres://postgres:secret@127.0.0.1:5432/postgres`.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gloss/pg
import gloss/sql
import gloss/sql/pool

fn with_db(size: Int, test_: fn(pool.Db) -> Nil) -> Nil {
  case getenv("GLOSS_TEST_PG_URL") {
    Error(Nil) -> Nil
    Ok(url) -> {
      let assert Ok(config) = pg.from_url(url)
      let assert Ok(db) =
        pool.new(pg.driver(config))
        |> pool.size(size)
        |> pool.query_timeout(duration.milliseconds(500))
        |> pool.start
      test_(db)
      pool.shutdown(db)
    }
  }
}

fn count(db: pool.Db, table: String) -> Int {
  let assert Ok(n) =
    sql.query("select count(*) from " <> table)
    |> sql.returning(decode.at([0], decode.int))
    |> pool.one(db, _)
  n
}

pub fn reads_column_types_test() {
  use db <- with_db(1)
  let row = {
    use int <- decode.field(0, decode.int)
    use float <- decode.field(1, decode.float)
    use bool <- decode.field(2, decode.bool)
    use text <- decode.field(3, decode.string)
    use bytes <- decode.field(4, decode.bit_array)
    use date <- decode.field(5, sql.date_decoder())
    use time <- decode.field(6, sql.time_decoder())
    use at <- decode.field(7, sql.timestamp_decoder())
    use ints <- decode.field(8, decode.list(decode.int))
    use null <- decode.field(9, decode.optional(decode.string))
    use numeric <- decode.field(10, decode.string)
    decode.success(#(
      #(int, float, bool, text, bytes),
      #(date, time, at, ints, null, numeric),
    ))
  }
  let assert Ok(values) =
    sql.query(
      "select 9000000000::int8, 1.5::float8, true, 'héllo'::text,
              '\\x00ff'::bytea, '2024-02-29'::date, '03:04:05.5'::time,
              '2024-01-02 03:04:05+00'::timestamptz, array[1, 2],
              null::text, 12.50::numeric",
    )
    |> sql.returning(row)
    |> pool.one(db, _)
  assert values
    == #(
      #(9_000_000_000, 1.5, True, "héllo", <<0, 255>>),
      #(
        calendar.Date(2024, calendar.February, 29),
        calendar.TimeOfDay(3, 4, 5, 500_000_000),
        timestamp.from_unix_seconds(1_704_164_645),
        [1, 2],
        None,
        "12.50",
      ),
    )
}

pub fn round_trips_arguments_test() {
  use db <- with_db(1)
  let at =
    timestamp.from_unix_seconds_and_nanoseconds(1_704_164_645, 123_456_000)
  let args = [
    sql.Text("it's \"quoted\""),
    sql.Int(-42),
    sql.Bool(False),
    sql.Timestamp(at),
    sql.Date(calendar.Date(2024, calendar.March, 1)),
    sql.Bytes(<<1, 2, 3>>),
    sql.Array([sql.Text("a,b"), sql.Null, sql.Text("{c}")]),
    sql.Float(0.1),
    sql.Null,
  ]
  let assert Ok(row) =
    list.fold(
      args,
      sql.query(
        "select $1::text, $2::int8, $3::bool, $4::timestamptz, $5::date,
                $6::bytea, $7::text[], $8::float8, $9::int",
      ),
      sql.bind,
    )
    |> sql.returning({
      use text <- decode.field(0, decode.string)
      use int <- decode.field(1, decode.int)
      use bool <- decode.field(2, decode.bool)
      use at <- decode.field(3, sql.timestamp_decoder())
      use bytes <- decode.field(5, decode.bit_array)
      use array <- decode.field(6, decode.list(decode.optional(decode.string)))
      use float <- decode.field(7, decode.float)
      use null <- decode.field(8, decode.optional(decode.int))
      decode.success(#(text, int, bool, at, bytes, array, float, null))
    })
    |> pool.one(db, _)
  assert row
    == #(
      "it's \"quoted\"",
      -42,
      False,
      at,
      <<1, 2, 3>>,
      [Some("a,b"), None, Some("{c}")],
      0.1,
      None,
    )
}

pub fn maps_constraint_errors_test() {
  use db <- with_db(1)
  let assert Ok(Nil) =
    pool.script(
      db,
      "create temp table people (
         id serial primary key,
         email text not null constraint people_email_key unique,
         age int check (age >= 0)
       );
       insert into people (email) values ('a@x');",
    )
  let insert = fn(email, age) {
    sql.query("insert into people (email, age) values ($1, $2)")
    |> sql.bind(email)
    |> sql.bind(age)
    |> pool.exec(db, _)
  }
  let assert Error(sql.UniqueViolation(constraint: "people_email_key", ..)) =
    insert(sql.Text("a@x"), sql.Null)
  let assert Error(sql.NotNullViolation(column: "email", ..)) =
    insert(sql.Null, sql.Null)
  let assert Error(sql.CheckViolation(constraint: "people_age_check", ..)) =
    insert(sql.Text("b@x"), sql.Int(-1))
  assert insert(sql.Text("b@x"), sql.Int(3)) == Ok(1)
  assert pool.exec(db, sql.query("update people set age = 1")) == Ok(2)
}

pub fn a_failed_statement_leaves_the_connection_usable_test() {
  use db <- with_db(1)
  let assert Error(sql.QueryFailed(code: "42601", ..)) =
    pool.exec(db, sql.query("selec 1"))
  let assert Error(sql.QueryFailed(code: "42P01", ..)) =
    pool.exec(db, sql.query("select * from no_such_table"))
  assert pool.exec(db, sql.query("select 1")) == Ok(1)
}

pub fn transactions_commit_and_roll_back_test() {
  use db <- with_db(1)
  let assert Ok(Nil) = pool.script(db, "create temp table items (name text)")
  let add = fn(db, name) {
    sql.query("insert into items values ($1)")
    |> sql.bind(sql.Text(name))
    |> pool.exec(db, _)
  }

  let assert Error(sql.RolledBack("no")) =
    pool.transaction(db, fn(tx) {
      let _ = add(tx, "dropped")
      Error("no")
    })
  assert count(db, "items") == 0

  let assert Ok(Nil) =
    pool.transaction(db, fn(tx) {
      let _ = add(tx, "kept")
      let _ =
        pool.transaction(tx, fn(inner) {
          let _ = add(inner, "undone")
          Error(Nil)
        })
      Ok(Nil)
    })
  assert count(db, "items") == 1
}

pub fn a_slow_statement_times_out_test() {
  use db <- with_db(1)
  assert pool.exec(db, sql.query("select pg_sleep(2)"))
    == Error(sql.QueryTimeout)
  assert pool.exec(db, sql.query("select 1")) == Ok(1)
}

pub fn a_timeout_inside_a_transaction_breaks_the_connection_test() {
  use db <- with_db(1)
  let select_42 =
    sql.query("select 42") |> sql.returning(decode.at([0], decode.int))
  let assert Error(sql.RolledBack(sql.ConnectionLost(_))) =
    pool.transaction(db, fn(tx) {
      let assert Error(sql.QueryTimeout) =
        pool.exec(tx, sql.query("select pg_sleep(0.7)"))
      // pg_sleep's replies are still coming. Reading them as this
      // statement's would return the wrong rows.
      process.sleep(300)
      pool.one(tx, select_42)
    })
  assert pool.one(db, select_42) == Ok(42)
}

pub fn serves_concurrent_callers_test() {
  use db <- with_db(3)
  let results = process.new_subject()
  one_to(20)
  |> list.each(fn(i) {
    process.spawn(fn() {
      let result =
        sql.query("select $1::int * 2")
        |> sql.bind(sql.Int(i))
        |> sql.returning(decode.at([0], decode.int))
        |> pool.one(db, _)
      process.send(results, result)
    })
  })
  let total =
    one_to(20)
    |> list.map(fn(_) {
      let assert Ok(Ok(n)) = process.receive(results, 5000)
      n
    })
    |> list.fold(0, fn(a, b) { a + b })
  assert total == 420
}

pub fn a_wrong_password_fails_to_connect_test() {
  case getenv("GLOSS_TEST_PG_URL") |> result.try(pg.from_url) {
    Error(Nil) -> Nil
    Ok(config) -> {
      let assert Ok(db) =
        pool.new(pg.driver(pg.password(config, "wrong"))) |> pool.start
      let assert Error(sql.ConnectionFailed(_)) =
        pool.exec(db, sql.query("select 1"))
      pool.shutdown(db)
    }
  }
}

fn one_to(n: Int) -> List(Int) {
  case n {
    0 -> []
    _ -> list.append(one_to(n - 1), [n])
  }
}

/// Runs when the test server has TLS on, e.g. with GLOSS_TEST_PG_TLS=1.
pub fn connects_over_tls_test() {
  case getenv("GLOSS_TEST_PG_TLS"), getenv("GLOSS_TEST_PG_URL") {
    Ok(_), Ok(url) -> {
      let assert Ok(config) = pg.from_url(url <> "?sslmode=require")
      let assert Ok(db) =
        pool.new(pg.driver(config)) |> pool.size(2) |> pool.start
      // Statements run in the calling process while the pool owns the
      // TLS socket; run several so connections are reused.
      list.each(one_to(5), fn(_) {
        let assert Ok(True) =
          sql.query("select ssl from pg_stat_ssl where pid = pg_backend_pid()")
          |> sql.returning(decode.at([0], decode.bool))
          |> pool.one(db, _)
      })
      // The listener's socket runs in active mode over TLS.
      let assert Ok(listener) = pg.start_listener(config)
      let inbox = process.new_subject()
      let assert Ok(Nil) = pg.listen(listener, "tls", inbox)
      let assert Ok(1) = pool.exec(db, pg.notify("tls", "secure"))
      let assert Ok(pg.Notification(payload: "secure", ..)) =
        process.receive(inbox, 2000)
      pg.stop_listener(listener)
      // A self-signed certificate fails verification.
      let assert Ok(db) =
        pool.new(pg.driver(pg.ssl(config, pg.SslVerified))) |> pool.start
      let assert Error(sql.ConnectionFailed(_)) =
        pool.exec(db, sql.query("select 1"))
      Nil
    }
    _, _ -> Nil
  }
}

@external(erlang, "pg_test_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

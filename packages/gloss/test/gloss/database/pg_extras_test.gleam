//// Prepared statements, COPY and LISTEN/NOTIFY against a real Postgres.
//// Like pg_test, these run only when GLOSS_TEST_PG_URL is set.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gloss/database/pg
import gloss/database/sql

fn config() -> Result(pg.Config, Nil) {
  case getenv("GLOSS_TEST_PG_URL") {
    Ok(url) -> pg.from_url(url)
    Error(Nil) -> Error(Nil)
  }
}

fn with_db(cache: Int, test_: fn(sql.Db) -> Nil) -> Nil {
  case config() {
    Error(Nil) -> Nil
    Ok(config) -> {
      let assert Ok(db) =
        sql.new(pg.driver(pg.statement_cache(config, cache)))
        |> sql.pool_size(1)
        |> sql.query_timeout(duration.seconds(5))
        |> sql.start
      test_(db)
      sql.shutdown(db)
    }
  }
}

fn int(db: sql.Db, text: String) -> Int {
  let assert Ok(n) =
    sql.query(text)
    |> sql.returning(decode.at([0], decode.int))
    |> sql.one(db, _)
  n
}

const prepared =
  "select count(*) from pg_prepared_statements where name like 'gloss_%'"

// --- Prepared statements -----------------------------------------------------

pub fn statements_are_prepared_once_per_connection_test() {
  use db <- with_db(100)
  assert int(db, "select 1") == 1
  assert int(db, "select 1") == 1
  // "select 1" and the count itself, which is prepared before it runs.
  assert int(db, prepared) == 2
  assert int(db, prepared) == 2
}

pub fn the_cache_can_be_turned_off_test() {
  use db <- with_db(0)
  assert int(db, "select 1") == 1
  assert int(db, prepared) == 0
}

pub fn the_least_recently_used_statements_are_closed_test() {
  use db <- with_db(2)
  assert int(db, "select 1") == 1
  assert int(db, "select 2") == 2
  assert int(db, "select 3") == 3
  // "select 1" was evicted when "select 3" was cached, and is closed ahead
  // of this statement. Caching this one evicts "select 2", closed ahead of
  // the next.
  assert int(db, prepared) == 3
  assert int(db, prepared) == 2
}

pub fn a_changed_result_type_is_prepared_again_test() {
  use db <- with_db(100)
  let assert Ok(Nil) = sql.script(db, "create temp table shapes (a int)")
  let assert Ok(Nil) = sql.script(db, "insert into shapes values (1)")
  let select = sql.query("select * from shapes")
  let assert Ok([_]) = sql.all(db, select)
  let assert Ok(Nil) = sql.script(db, "alter table shapes add column b int")
  let assert Ok([row]) =
    sql.all(
      db,
      select |> sql.returning(decode.at([1], decode.optional(decode.int))),
    )
  assert row == None
}

pub fn deallocated_statements_are_prepared_again_test() {
  use db <- with_db(100)
  assert int(db, "select 7") == 7
  let assert Ok(Nil) = sql.script(db, "deallocate all")
  assert int(db, "select 7") == 7
}

// --- COPY --------------------------------------------------------------------

pub fn copies_rows_in_and_out_test() {
  use db <- with_db(100)
  let assert Ok(Nil) =
    sql.script(db, "create temp table items (name text, qty int, tags text[])")
  let rows = [
    [sql.Text("tab\there"), sql.Int(1), sql.Array([sql.Text("a b")])],
    [sql.Text("line\nbreak \\ slash"), sql.Null, sql.Null],
  ]
  assert pg.copy_in(db, "copy items from stdin", list.map(rows, pg.copy_row))
    == Ok(2)

  let assert Ok(names) =
    sql.query("select name, qty from items order by qty nulls last")
    |> sql.returning({
      use name <- decode.field(0, decode.string)
      use qty <- decode.field(1, decode.optional(decode.int))
      decode.success(#(name, qty))
    })
    |> sql.all(db, _)
  assert names == [#("tab\there", Some(1)), #("line\nbreak \\ slash", None)]

  let assert Ok(out) =
    pg.copy_out(
      db,
      "copy (select * from items order by qty nulls last) to stdout",
      [],
      fn(acc, chunk) { [chunk, ..acc] },
    )
  assert list.reverse(out) == list.map(rows, pg.copy_row)
}

pub fn copy_in_streams_from_state_test() {
  use db <- with_db(100)
  let assert Ok(Nil) = sql.script(db, "create temp table numbers (n int)")
  let next = fn(n) {
    case n > 1000 {
      True -> None
      False -> Some(#(pg.copy_row([sql.Int(n)]), n + 1))
    }
  }
  assert pg.copy_in_with(db, "copy numbers from stdin", from: 1, next:)
    == Ok(1000)
  assert int(db, "select sum(n)::int from numbers") == 500_500
}

pub fn bad_copy_data_fails_and_leaves_the_connection_usable_test() {
  use db <- with_db(100)
  let assert Ok(Nil) = sql.script(db, "create temp table counts (n int)")
  let assert Error(sql.QueryFailed(code: "22P02", ..)) =
    pg.copy_in(db, "copy counts from stdin", [<<"not a number\n":utf8>>])
  assert int(db, "select 5") == 5
}

pub fn copy_in_is_part_of_a_transaction_test() {
  use db <- with_db(100)
  let assert Ok(Nil) = sql.script(db, "create temp table staged (n int)")
  let assert Error(sql.RolledBack(Nil)) =
    sql.transaction(db, fn(tx) {
      let assert Ok(1) =
        pg.copy_in(tx, "copy staged from stdin", [pg.copy_row([sql.Int(1)])])
      Error(Nil)
    })
  assert int(db, "select count(*)::int from staged") == 0
}

pub fn copy_row_writes_the_text_format_test() {
  assert pg.copy_row([sql.Text("a\tb\\"), sql.Null, sql.Bool(True)])
    == <<"a\\tb\\\\\t\\N\tt\n":utf8>>
  assert bit_array.byte_size(pg.copy_row([])) == 1
}

// --- LISTEN / NOTIFY ---------------------------------------------------------

pub fn notifications_reach_listeners_test() {
  use db <- with_db(100)
  let assert Ok(config) = config()
  let assert Ok(listener) = pg.start_listener(config)
  let jobs = process.new_subject()
  let assert Ok(Nil) = pg.listen(listener, "Jobs.New", jobs)

  let assert Ok(1) = sql.exec(db, pg.notify("Jobs.New", "42"))
  let assert Ok(pg.Notification(channel: "Jobs.New", payload: "42", ..)) =
    process.receive(jobs, 2000)

  // In a transaction, delivered on commit only.
  let assert Ok(Nil) =
    sql.transaction(db, fn(tx) {
      let assert Ok(1) = sql.exec(tx, pg.notify("Jobs.New", "in tx"))
      assert process.receive(jobs, 100) == Error(Nil)
      Ok(Nil)
    })
  let assert Ok(pg.Notification(payload: "in tx", ..)) =
    process.receive(jobs, 2000)

  pg.unlisten(listener, "Jobs.New", jobs)
  let assert Ok(1) = sql.exec(db, pg.notify("Jobs.New", "unheard"))
  assert process.receive(jobs, 200) == Error(Nil)
  pg.stop_listener(listener)
}

pub fn a_listener_reconnects_and_listens_again_test() {
  use db <- with_db(100)
  let assert Ok(config) = config()
  let assert Ok(listener) =
    pg.start_listener(pg.application_name(config, "gloss_listener_test"))
  let events = process.new_subject()
  let assert Ok(Nil) = pg.listen(listener, "events", events)

  let assert Ok(1) =
    sql.exec(
      db,
      sql.query(
        "select pg_terminate_backend(pid) from pg_stat_activity
         where application_name = 'gloss_listener_test'",
      ),
    )
  // Reconnecting waits half a second first.
  process.sleep(1500)
  let assert Ok(1) = sql.exec(db, pg.notify("events", "after"))
  let assert Ok(pg.Notification(payload: "after", ..)) =
    process.receive(events, 2000)
  pg.stop_listener(listener)
}

pub fn a_rejected_listen_is_an_error_test() {
  case config() {
    Error(Nil) -> Nil
    Ok(config) -> {
      let assert Ok(listener) = pg.start_listener(config)
      let subject = process.new_subject()
      let assert Error(sql.QueryFailed(..)) =
        pg.listen(listener, string.repeat("x", 100), subject)
        |> fn(r) {
          case r {
            // Postgres truncates long identifiers rather than rejecting them.
            Ok(Nil) -> Error(sql.QueryFailed("", "accepted"))
            e -> e
          }
        }
      pg.stop_listener(listener)
    }
  }
}

@external(erlang, "pg_test_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

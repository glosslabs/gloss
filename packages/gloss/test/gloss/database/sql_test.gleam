import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration
import gloss/database/sql
import gloss/tracer
import sql_fake_driver as fake

type User {
  User(id: Int, name: Option(String))
}

fn user() -> decode.Decoder(User) {
  use id <- decode.field(0, decode.int)
  use name <- decode.field(1, decode.optional(decode.string))
  decode.success(User(id:, name:))
}

fn start(size: Int) -> #(sql.Db, process.Subject(String)) {
  let log = process.new_subject()
  let assert Ok(db) =
    sql.new(fake.driver(log)) |> sql.pool_size(size) |> sql.start
  #(db, log)
}

fn users() -> sql.Statement(User) {
  sql.query("select id, name from users") |> sql.returning(user())
}

pub fn all_decodes_rows_by_position_test() {
  let #(db, _) = start(1)
  assert sql.all(db, users()) == Ok([User(1, Some("sam")), User(2, None)])
}

pub fn one_wants_exactly_one_row_test() {
  let #(db, _) = start(1)
  assert sql.one(db, users()) == Error(sql.TooManyRows(2))
  assert sql.optional(db, users()) == Error(sql.TooManyRows(2))
  let none = sql.query("select nothing") |> sql.returning(user())
  assert sql.one(db, none) == Error(sql.NotFound)
  assert sql.optional(db, none) == Ok(None)
}

pub fn decode_failures_name_the_row_test() {
  let #(db, _) = start(1)
  let ids =
    sql.query("select id, name from users")
    |> sql.returning(decode.at([1], decode.string))
  let assert Error(sql.DecodeFailed(row: 1, errors: [_])) = sql.all(db, ids)
}

pub fn exec_returns_affected_rows_test() {
  let #(db, log) = start(1)
  assert sql.exec(db, sql.query("delete from users")) == Ok(1)
  assert fake.drain(log) == ["connect", "delete from users"]
}

pub fn arg_numbers_placeholders_after_bound_values_test() {
  let statement =
    sql.query("select * from users where org = $1")
    |> sql.bind(sql.Int(7))
    |> sql.when(Some("active"), fn(s, status) {
      s |> sql.append(" and status = ") |> sql.arg(sql.Text(status))
    })
    |> sql.when(None, fn(s, q) { s |> sql.append(" and name = ") |> sql.arg(q) })
    |> sql.append(" limit ")
    |> sql.arg(sql.Int(10))
  assert sql.render(statement, fn(n) { "$" <> int.to_string(n) })
    == #("select * from users where org = $1 and status = $2 limit $3", [
      sql.Int(7),
      sql.Text("active"),
      sql.Int(10),
    ])
}

pub fn borrow_lends_the_drivers_connection_test() {
  let #(db, log) = start(1)
  let raw = fn(db) {
    sql.borrow(db, "raw", fn(connection, _timeout) {
      decode.run(connection.raw, decode.string)
      |> result.replace_error(sql.NotFound)
    })
  }
  assert raw(db) == Ok("fake")
  let assert Ok(Ok("fake")) = sql.transaction(db, fn(tx) { Ok(raw(tx)) })
  assert fake.drain(log) == ["connect", "BEGIN", "COMMIT"]
}

pub fn nullable_maps_none_to_null_test() {
  assert sql.nullable(Some(3), sql.Int) == sql.Int(3)
  assert sql.nullable(None, sql.Int) == sql.Null
}

pub fn transaction_commits_on_ok_test() {
  let #(db, log) = start(1)
  let assert Ok(1) =
    sql.transaction(db, fn(tx) { sql.exec(tx, sql.query("insert x")) })
  assert fake.drain(log) == ["connect", "BEGIN", "insert x", "COMMIT"]
}

pub fn transaction_rolls_back_on_error_test() {
  let #(db, log) = start(1)
  let assert Error(sql.RolledBack(sql.QueryFailed(..))) =
    sql.transaction(db, fn(tx) { sql.all(tx, sql.query("select broken")) })
  assert fake.drain(log) == ["connect", "BEGIN", "select broken", "ROLLBACK"]
}

pub fn nested_transactions_are_savepoints_test() {
  let #(db, log) = start(1)
  let assert Ok(Error(sql.RolledBack("inner"))) =
    sql.transaction(db, fn(tx) {
      Ok(sql.transaction(tx, fn(_) { Error("inner") }))
    })
  assert fake.drain(log)
    == [
      "connect",
      "BEGIN",
      "SAVEPOINT gloss_1",
      "ROLLBACK TO SAVEPOINT gloss_1",
      "COMMIT",
    ]
}

pub fn a_panicking_transaction_rolls_back_and_frees_its_connection_test() {
  let #(db, log) = start(1)
  let assert Error(_) =
    rescue(fn() { sql.transaction(db, fn(_) { panic as "boom" }) })
  // The connection was in a transaction when the body panicked, so it is
  // closed rather than reused, and the pool opens another.
  assert sql.exec(db, sql.query("select 1")) == Ok(1)
  assert fake.drain(log)
    == ["connect", "BEGIN", "ROLLBACK", "close", "connect", "select 1"]
}

pub fn connections_are_reused_test() {
  let #(db, log) = start(2)
  let _ = sql.exec(db, sql.query("a"))
  let _ = sql.exec(db, sql.query("b"))
  assert fake.drain(log) == ["connect", "a", "b"]
}

pub fn a_timed_out_connection_is_closed_test() {
  let #(db, log) = start(1)
  assert sql.exec(db, sql.query("select slow")) == Error(sql.QueryTimeout)
  let _ = sql.exec(db, sql.query("select 1"))
  assert fake.drain(log)
    == ["connect", "select slow", "close", "connect", "select 1"]
}

pub fn checkout_times_out_when_the_pool_is_exhausted_test() {
  let log = process.new_subject()
  let assert Ok(db) =
    sql.new(fake.driver(log))
    |> sql.pool_size(1)
    |> sql.checkout_timeout(duration.milliseconds(50))
    |> sql.start
  let holding = process.new_subject()
  process.spawn(fn() {
    sql.transaction(db, fn(_) {
      let release = process.new_subject()
      process.send(holding, release)
      process.receive(release, 1000)
    })
  })
  let assert Ok(release) = process.receive(holding, 1000)
  assert sql.exec(db, sql.query("x")) == Error(sql.PoolTimeout)
  process.send(release, Nil)
}

pub fn a_dead_borrower_loses_its_connection_test() {
  let #(db, log) = start(1)
  let holding = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      sql.transaction(db, fn(_) {
        process.send(holding, Nil)
        process.sleep_forever()
        Ok(Nil)
      })
    })
  let assert Ok(Nil) = process.receive(holding, 1000)
  process.kill(pid)
  // The killed process may have been mid-statement: its connection is
  // closed and a fresh one serves the next caller.
  assert sql.exec(db, sql.query("after")) == Ok(1)
  assert fake.drain(log) == ["connect", "BEGIN", "close", "connect", "after"]
}

pub fn a_stopped_pool_is_unavailable_test() {
  let log = process.new_subject()
  let db = sql.new(fake.driver(log)) |> sql.db
  assert sql.exec(db, sql.query("x")) == Error(sql.Unavailable)
}

pub fn statements_in_a_transaction_are_its_children_test() {
  let spans = process.new_subject()
  let log = process.new_subject()
  let assert Ok(db) =
    sql.new(fake.driver(log))
    |> sql.tracer(tracer.new() |> tracer.handle(process.send(spans, _)))
    |> sql.start
  let parent = tracer.root()
  let db = sql.child_of(db, parent)

  let _ =
    sql.transaction(db, fn(tx) {
      sql.exec(tx, sql.query("insert into t values (1)") |> sql.label("t.add"))
    })

  let assert Ok(tracer.Span(
    name: "t.add",
    trace: query,
    parent_span_id: Some(q_parent),
    error: None,
    meta:,
    ..,
  )) = process.receive(spans, 100)
  let assert Ok(tracer.Span(
    name: "transaction",
    trace: tx,
    parent_span_id: Some(tx_parent),
    ..,
  )) = process.receive(spans, 100)
  assert q_parent == tx.span_id
  assert tx_parent == parent.span_id
  assert query.trace_id == parent.trace_id
  assert list.key_find(meta, "rows") |> result.is_ok
}

pub fn failed_statements_are_failed_spans_test() {
  let spans = process.new_subject()
  let log = process.new_subject()
  let assert Ok(db) =
    sql.new(fake.driver(log))
    |> sql.tracer(tracer.new() |> tracer.handle(process.send(spans, _)))
    |> sql.start
  let _ = sql.all(db, sql.query("select broken"))
  let assert Ok(tracer.Span(name: "select", error: Some(_), ..)) =
    process.receive(spans, 100)
}

@external(erlang, "gloss@database@sql_ffi", "rescue")
fn rescue(work: fn() -> a) -> Result(a, b)

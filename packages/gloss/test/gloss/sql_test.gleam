import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration
import gloss/sql
import gloss/sql/pool
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

fn start(size: Int) -> #(pool.Db, process.Subject(String)) {
  let log = process.new_subject()
  let assert Ok(db) =
    pool.new(fake.driver(log)) |> pool.size(size) |> pool.start
  #(db, log)
}

fn users() -> sql.Statement(User) {
  sql.query("select id, name from users") |> sql.returning(user())
}

pub fn all_decodes_rows_by_position_test() {
  let #(db, _) = start(1)
  assert pool.all(db, users()) == Ok([User(1, Some("sam")), User(2, None)])
}

pub fn one_wants_exactly_one_row_test() {
  let #(db, _) = start(1)
  assert pool.one(db, users()) == Error(sql.TooManyRows(2))
  assert pool.optional(db, users()) == Error(sql.TooManyRows(2))
  let none = sql.query("select nothing") |> sql.returning(user())
  assert pool.one(db, none) == Error(sql.NotFound)
  assert pool.optional(db, none) == Ok(None)
}

pub fn decode_failures_name_the_row_test() {
  let #(db, _) = start(1)
  let ids =
    sql.query("select id, name from users")
    |> sql.returning(decode.at([1], decode.string))
  let assert Error(sql.DecodeFailed(row: 1, errors: [_])) = pool.all(db, ids)
}

pub fn exec_returns_affected_rows_test() {
  let #(db, log) = start(1)
  assert pool.exec(db, sql.query("delete from users")) == Ok(1)
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
  assert sql.render(statement, sql.Postgres)
    == #("select * from users where org = $1 and status = $2 limit $3", [
      sql.Int(7),
      sql.Text("active"),
      sql.Int(10),
    ])
}

pub fn borrow_lends_the_drivers_connection_test() {
  let #(db, log) = start(1)
  let raw = fn(db) {
    pool.borrow(db, "raw", fn(connection, _timeout) {
      decode.run(connection.raw, decode.string)
      |> result.replace_error(sql.NotFound)
    })
  }
  assert raw(db) == Ok("fake")
  let assert Ok(Ok("fake")) = pool.transaction(db, fn(tx) { Ok(raw(tx)) })
  // Borrowed work can't take BEGIN along, so it is sent first.
  assert fake.drain(log) == ["connect", "BEGIN", "COMMIT"]
}

pub fn nullable_maps_none_to_null_test() {
  assert sql.nullable(Some(3), sql.Int) == sql.Int(3)
  assert sql.nullable(None, sql.Int) == sql.Null
}

pub fn transaction_commits_on_ok_test() {
  let #(db, log) = start(1)
  let assert Ok(1) =
    pool.transaction(db, fn(tx) { pool.exec(tx, sql.query("insert x")) })
  assert fake.drain(log) == ["connect", "BEGIN; insert x", "COMMIT"]
}

pub fn only_the_first_statement_carries_begin_test() {
  let #(db, log) = start(1)
  let assert Ok(1) =
    pool.transaction(db, fn(tx) {
      use _ <- result.try(pool.exec(tx, sql.query("insert x")))
      pool.exec(tx, sql.query("insert y"))
    })
  assert fake.drain(log) == ["connect", "BEGIN; insert x", "insert y", "COMMIT"]
}

pub fn an_empty_transaction_sends_nothing_test() {
  let #(db, log) = start(1)
  assert pool.transaction(db, fn(_) { Ok(1) }) == Ok(1)
  assert pool.transaction(db, fn(_) { Error("no") })
    == Error(sql.RolledBack("no"))
  let _ = pool.exec(db, sql.query("select 1"))
  assert fake.drain(log) == ["connect", "select 1"]
}

pub fn without_pipelining_begin_is_sent_first_test() {
  let log = process.new_subject()
  let assert Ok(db) = pool.new(fake.unpipelined(log)) |> pool.start
  let assert Ok(1) =
    pool.transaction(db, fn(tx) { pool.exec(tx, sql.query("insert x")) })
  assert fake.drain(log) == ["connect", "BEGIN", "insert x", "COMMIT"]
}

pub fn transaction_rolls_back_on_error_test() {
  let #(db, log) = start(1)
  let assert Error(sql.RolledBack(sql.QueryFailed(..))) =
    pool.transaction(db, fn(tx) { pool.all(tx, sql.query("select broken")) })
  assert fake.drain(log) == ["connect", "BEGIN; select broken", "ROLLBACK"]
}

pub fn flatten_merges_transaction_failures_test() {
  let #(db, _) = start(1)
  assert pool.transaction(db, fn(tx) { pool.exec(tx, sql.query("x")) })
    |> sql.flatten
    == Ok(1)
  let assert Error(sql.QueryFailed(..)) =
    pool.transaction(db, fn(tx) { pool.all(tx, sql.query("select broken")) })
    |> sql.flatten
  assert sql.flatten(Error(sql.TransactionFailed(sql.PoolTimeout)))
    == Error(sql.PoolTimeout)
}

pub fn nested_transactions_are_savepoints_test() {
  let #(db, log) = start(1)
  let assert Ok(Error(sql.RolledBack(sql.QueryFailed(..)))) =
    pool.transaction(db, fn(tx) {
      use _ <- result.try(pool.exec(tx, sql.query("insert x")))
      Ok(
        pool.transaction(tx, fn(tx) {
          pool.exec(tx, sql.query("select broken"))
        }),
      )
    })
  assert fake.drain(log)
    == [
      "connect",
      "BEGIN; insert x",
      "SAVEPOINT gloss_1; select broken",
      "ROLLBACK TO SAVEPOINT gloss_1",
      "COMMIT",
    ]
}

pub fn a_nested_first_statement_opens_every_level_test() {
  let #(db, log) = start(1)
  let assert Ok(Ok(1)) =
    pool.transaction(db, fn(tx) {
      Ok(pool.transaction(tx, fn(tx) { pool.exec(tx, sql.query("insert x")) }))
    })
  assert fake.drain(log)
    == [
      "connect",
      "BEGIN; SAVEPOINT gloss_1; insert x",
      "RELEASE SAVEPOINT gloss_1",
      "COMMIT",
    ]
}

pub fn a_panicking_transaction_rolls_back_and_frees_its_connection_test() {
  let #(db, log) = start(1)
  let assert Error(_) =
    rescue(fn() { pool.transaction(db, fn(_) { panic as "boom" }) })
  // The connection was in a transaction when the body panicked, so it is
  // closed rather than reused, and the pool opens another.
  assert pool.exec(db, sql.query("select 1")) == Ok(1)
  assert fake.drain(log) == ["connect", "close", "connect", "select 1"]
}

pub fn connections_are_reused_test() {
  let #(db, log) = start(2)
  let _ = pool.exec(db, sql.query("a"))
  let _ = pool.exec(db, sql.query("b"))
  assert fake.drain(log) == ["connect", "a", "b"]
}

pub fn a_timed_out_connection_is_closed_test() {
  let #(db, log) = start(1)
  assert pool.exec(db, sql.query("select slow")) == Error(sql.QueryTimeout)
  let _ = pool.exec(db, sql.query("select 1"))
  assert fake.drain(log)
    == ["connect", "select slow", "close", "connect", "select 1"]
}

pub fn checkout_times_out_when_the_pool_is_exhausted_test() {
  let log = process.new_subject()
  let assert Ok(db) =
    pool.new(fake.driver(log))
    |> pool.size(1)
    |> pool.checkout_timeout(duration.milliseconds(50))
    |> pool.start
  let holding = process.new_subject()
  process.spawn(fn() {
    pool.transaction(db, fn(_) {
      let release = process.new_subject()
      process.send(holding, release)
      process.receive(release, 1000)
    })
  })
  let assert Ok(release) = process.receive(holding, 1000)
  assert pool.exec(db, sql.query("x")) == Error(sql.PoolTimeout)
  process.send(release, Nil)
}

pub fn a_dead_borrower_loses_its_connection_test() {
  let #(db, log) = start(1)
  let holding = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      pool.transaction(db, fn(_) {
        process.send(holding, Nil)
        process.sleep_forever()
        Ok(Nil)
      })
    })
  let assert Ok(Nil) = process.receive(holding, 1000)
  process.kill(pid)
  // The killed process may have been mid-statement: its connection is
  // closed and a fresh one serves the next caller.
  assert pool.exec(db, sql.query("after")) == Ok(1)
  assert fake.drain(log) == ["connect", "close", "connect", "after"]
}

pub fn a_stopped_pool_is_unavailable_test() {
  let log = process.new_subject()
  let db = pool.new(fake.driver(log)) |> pool.db
  assert pool.exec(db, sql.query("x")) == Error(sql.Unavailable)
}

pub fn statements_in_a_transaction_are_its_children_test() {
  let spans = process.new_subject()
  let log = process.new_subject()
  let assert Ok(db) =
    pool.new(fake.driver(log))
    |> pool.tracer(tracer.new() |> tracer.handle(process.send(spans, _)))
    |> pool.start
  let parent = tracer.root()
  let db = pool.child_of(db, parent)

  let _ =
    pool.transaction(db, fn(tx) {
      pool.exec(tx, sql.query("insert into t values (1)") |> sql.label("t.add"))
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
    pool.new(fake.driver(log))
    |> pool.tracer(tracer.new() |> tracer.handle(process.send(spans, _)))
    |> pool.start
  let _ = pool.all(db, sql.query("select broken"))
  let assert Ok(tracer.Span(name: "select", error: Some(_), ..)) =
    process.receive(spans, 100)
}

@external(erlang, "gloss@sql_ffi", "rescue")
fn rescue(work: fn() -> a) -> Result(a, b)

pub fn statements_join_the_current_span_test() {
  let spans = process.new_subject()
  let log = process.new_subject()
  let assert Ok(db) =
    pool.new(fake.driver(log))
    |> pool.tracer(tracer.new() |> tracer.handle(process.send(spans, _)))
    |> pool.start
  let request = tracer.root()
  let assert Ok(_) =
    tracer.with_current(request, fn() { pool.exec(db, sql.query("select 1")) })

  let assert Ok(tracer.Span(trace:, parent_span_id: Some(parent), ..)) =
    process.receive(spans, 100)
  assert parent == request.span_id
  assert trace.trace_id == request.trace_id
}

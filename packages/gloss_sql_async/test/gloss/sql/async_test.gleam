import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/string
import gloss/sql
import gloss/sql/async

type Log

@external(javascript, "../../fake_ffi.mjs", "new_log")
fn new_log() -> Log

@external(javascript, "../../fake_ffi.mjs", "push")
fn push(log: Log, entry: String) -> Nil

@external(javascript, "../../fake_ffi.mjs", "entries")
fn entries(log: Log) -> List(String)

@external(javascript, "../../fake_ffi.mjs", "delay")
fn delay(ms: Int) -> Promise(Nil)

/// A database that logs each statement when it starts and when it ends,
/// taking `ms` to answer. `select n` returns n; `fail` fails.
fn fake(log: Log, ms: Int) -> async.Database {
  async.database(
    name: "fake",
    placeholder: fn(n) { "$" <> int.to_string(n) },
    run: fn(text, args) {
      push(log, "start " <> text)
      use _ <- promise.await(delay(ms))
      push(log, "end " <> text)
      promise.resolve(case text {
        "fail" -> Error(sql.QueryFailed(code: "x", message: "failed"))
        "select n" -> Ok(sql.Outcome(rows: [args], affected: 1))
        _ -> Ok(sql.Outcome(rows: [], affected: 3))
      })
    },
    script: fn(text) {
      push(log, text)
      promise.resolve(Ok(Nil))
    },
    close: fn() {
      push(log, "close")
      promise.resolve(Nil)
    },
  )
}

fn number(n: Int) -> sql.Statement(Int) {
  sql.query("select n")
  |> sql.bind(sql.Int(n))
  |> sql.returning(decode.at([0], decode.int))
}

pub fn statements_decode_rows_test() -> Promise(Nil) {
  let db = fake(new_log(), 0)
  use one <- promise.await(async.one(db, number(7)))
  assert one == Ok(7)
  use all <- promise.await(async.all(db, number(8)))
  assert all == Ok([8])
  use affected <- promise.await(async.exec(db, sql.query("update")))
  assert affected == Ok(3)
  use failed <- promise.await(async.one(db, sql.query("fail")))
  let assert Error(sql.QueryFailed(..)) = failed
  promise.resolve(Nil)
}

pub fn calls_run_one_at_a_time_in_order_test() -> Promise(Nil) {
  let log = new_log()
  let db = fake(log, 5)
  use _ <- promise.await(
    promise.await_list([
      async.exec(db, sql.query("a")),
      async.exec(db, sql.query("b")),
    ]),
  )
  assert entries(log) == ["start a", "end a", "start b", "end b"]
  promise.resolve(Nil)
}

pub fn other_calls_wait_for_a_transaction_test() -> Promise(Nil) {
  let log = new_log()
  let db = fake(log, 5)
  let tx =
    async.transaction(db, fn(tx) {
      use _ <- promise.try_await(async.exec(tx, sql.query("in tx 1")))
      async.exec(tx, sql.query("in tx 2"))
    })
  // Made while the transaction is open: it must not run inside it.
  let outside = async.exec(db, sql.query("outside"))
  use result <- promise.await(tx)
  assert result == Ok(3)
  use _ <- promise.await(outside)
  assert entries(log)
    == [
      "BEGIN", "start in tx 1", "end in tx 1", "start in tx 2", "end in tx 2",
      "COMMIT", "start outside", "end outside",
    ]
  promise.resolve(Nil)
}

pub fn errors_roll_back_and_nest_as_savepoints_test() -> Promise(Nil) {
  let log = new_log()
  let db = fake(log, 0)
  use result <- promise.await(
    async.transaction(db, fn(tx) {
      use inner <- promise.await(
        async.transaction(tx, fn(inner) {
          use _ <- promise.await(async.exec(inner, sql.query("x")))
          promise.resolve(Error("undo"))
        }),
      )
      assert inner == Error(sql.RolledBack("undo"))
      promise.resolve(Error("outer"))
    }),
  )
  assert result == Error(sql.RolledBack("outer"))
  assert list.filter(entries(log), fn(e) {
      !string.starts_with(e, "start") && !string.starts_with(e, "end")
    })
    == [
      "BEGIN", "SAVEPOINT gloss_1", "ROLLBACK TO SAVEPOINT gloss_1", "ROLLBACK",
    ]
  promise.resolve(Nil)
}

pub fn a_failing_body_rolls_back_and_frees_the_queue_test() -> Promise(Nil) {
  let log = new_log()
  let db = fake(log, 0)
  use rejected <- promise.await(
    promise.rescue(
      async.transaction(db, fn(_tx) { panic as "boom" })
        |> promise.map(fn(_) { "resolved" }),
      fn(_) { "rejected" },
    ),
  )
  assert rejected == "rejected"
  // The database still answers.
  use after <- promise.await(async.one(db, number(1)))
  assert after == Ok(1)
  assert list.take(entries(log), 2) == ["BEGIN", "ROLLBACK"]
  promise.resolve(Nil)
}

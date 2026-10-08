import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{None}
import gleam/string
import gleam/time/timestamp
import gloss/pglite
import gloss/sql
import gloss/sql/internal/postgres
import gloss/sql_async.{type Database}
import gloss/sqlite_wasm
import gloss/url

pub fn main() -> Promise(Nil) {
  section("gloss/sql and gloss/url on JavaScript")
  let row = [
    sql.Int(1),
    sql.Text("ada@example.com"),
    sql.Bool(True),
    sql.Timestamp(timestamp.system_time()),
    sql.Float(1.5),
    sql.Null,
    sql.Text("Ada Lovelace"),
    sql.Int(42),
  ]
  let outcome = sql.Outcome(rows: list.repeat(row, 1000), affected: 1000)
  let statement =
    sql.query("")
    |> sql.returning({
      use id <- decode.field(0, decode.int)
      use email <- decode.field(1, decode.string)
      use active <- decode.field(2, decode.bool)
      use at <- decode.field(3, sql.timestamp_decoder())
      use score <- decode.field(4, decode.float)
      use bio <- decode.field(5, decode.optional(decode.string))
      use name <- decode.field(6, decode.string)
      use n <- decode.field(7, decode.int)
      decode.success(#(id, email, active, at, score, bio, name, n))
    })
  bench("decode 1000 rows of 8 columns", 200, fn() { sql.all(outcome, statement) })
  let ts = <<"2026-10-08 12:30:45.123456+00":utf8>>
  bench("postgres decode timestamptz", 200_000, fn() { postgres.decode(1184, ts) })
  let assert Ok(base) = url.parse("https://api.example.com/v1")
  bench("build a URL: 3 segments, 2 params", 100_000, fn() {
    base
    |> url.segments(["users", "42", "posts"])
    |> url.query("tag", "a&b")
    |> url.query("page", "2")
    |> url.to_string
  })
  bench("url.encode 120 chars", 100_000, fn() {
    url.encode(string.repeat("héllo wörld/", 10))
  })

  use opened <- promise.await(sqlite_wasm.open(sqlite_wasm.memory()))
  let assert Ok(db) = opened
  use _ <- promise.await(database("gloss/sqlite_wasm (memory)", db, "?1", "integer"))
  use opened <- promise.await(pglite.open(pglite.memory()))
  let assert Ok(db) = opened
  database("gloss/pglite (memory)", db, "$1", "serial")
}

fn database(
  title: String,
  db: Database,
  placeholder: String,
  key_type: String,
) -> Promise(Nil) {
  section(title)
  use _ <- promise.await(sql_async.script(
    db,
    "create table bench_users (id "
      <> key_type
      <> " primary key, email text not null, score int not null)",
  ))
  let insert = fn(n) {
    sql.query("insert into bench_users (email, score) values (")
    |> sql.append(placeholder)
    |> sql.append(", 1)")
    |> sql.bind(sql.Text("user" <> int.to_string(n) <> "@example.com"))
  }
  use _ <- promise.await(
    sql_async.transaction(db, fn(tx) {
      list.repeat(Nil, 1000)
      |> list.index_map(fn(_, n) { n })
      |> list.fold(promise.resolve(Ok(0)), fn(acc, n) {
        use _ <- promise.try_await(acc)
        sql_async.exec(tx, insert(n))
      })
    }),
  )
  let find =
    sql.query("select id, email, score from bench_users where id = ")
    |> sql.append(placeholder)
    |> sql.bind(sql.Int(500))
    |> sql.returning({
      use id <- decode.field(0, decode.int)
      use email <- decode.field(1, decode.string)
      use score <- decode.field(2, decode.int)
      decode.success(#(id, email, score))
    })
  use _ <- promise.await(
    bench_async("select 1", 2000, fn() {
      sql_async.one(db, sql.query("select 1") |> sql.returning(decode.at([0], decode.int)))
    }),
  )
  use _ <- promise.await(
    bench_async("select a row by id", 2000, fn() { sql_async.one(db, find) }),
  )
  use _ <- promise.await(
    bench_async("insert a row", 1000, fn() { sql_async.exec(db, insert(0)) }),
  )
  sql_async.close(db)
}

@external(javascript, "./harness_ffi.mjs", "bench")
fn bench(name: String, n: Int, f: fn() -> a) -> Nil

@external(javascript, "./harness_ffi.mjs", "bench_async")
fn bench_async(name: String, n: Int, f: fn() -> Promise(a)) -> Promise(Nil)

@external(javascript, "./harness_ffi.mjs", "section")
fn section(title: String) -> Nil

pub fn unused() {
  None
}

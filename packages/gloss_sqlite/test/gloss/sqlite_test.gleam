import gleam/dynamic/decode
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gloss/sql
import gloss/sql/pool
import gloss/sqlite

fn start(config: sqlite.Config) -> pool.Db {
  let assert Ok(db) =
    pool.new(sqlite.driver(config)) |> pool.size(3) |> pool.start
  let assert Ok(Nil) =
    pool.script(
      db,
      "create table if not exists users (
         id integer primary key,
         email text not null unique,
         active boolean not null default 1,
         joined timestamp,
         born date,
         wakes time,
         avatar blob,
         score real
       );
       create table if not exists posts (
         id integer primary key,
         user_id integer not null references users (id),
         likes integer not null check (likes >= 0)
       );",
    )
  db
}

type User {
  User(
    id: Int,
    email: String,
    active: Bool,
    joined: option.Option(timestamp.Timestamp),
    born: calendar.Date,
    wakes: calendar.TimeOfDay,
    avatar: BitArray,
    score: Float,
  )
}

fn user_decoder() {
  use id <- decode.field(0, decode.int)
  use email <- decode.field(1, decode.string)
  use active <- decode.field(2, decode.bool)
  use joined <- decode.field(3, decode.optional(sql.timestamp_decoder()))
  use born <- decode.field(4, sql.date_decoder())
  use wakes <- decode.field(5, sql.time_decoder())
  use avatar <- decode.field(6, decode.bit_array)
  use score <- decode.field(7, decode.float)
  decode.success(User(
    id:,
    email:,
    active:,
    joined:,
    born:,
    wakes:,
    avatar:,
    score:,
  ))
}

fn insert(db: pool.Db, email: String) -> Result(Int, sql.Error) {
  sql.query(
    "insert into users (email, active, joined, born, wakes, avatar, score)
     values (?1, ?2, ?3, ?4, ?5, ?6, ?7) returning id",
  )
  |> sql.bind(sql.Text(email))
  |> sql.bind(sql.Bool(False))
  |> sql.bind(
    sql.Timestamp(timestamp.from_unix_seconds_and_nanoseconds(
      1_700_000_000,
      250_000_000,
    )),
  )
  |> sql.bind(sql.Date(calendar.Date(1990, calendar.March, 2)))
  |> sql.bind(sql.Time(calendar.TimeOfDay(6, 30, 0, 0)))
  |> sql.bind(sql.Bytes(<<0, 1, 255>>))
  |> sql.bind(sql.Float(9.5))
  |> sql.returning(decode.at([0], decode.int))
  |> pool.one(db, _)
}

pub fn values_round_trip_test() {
  let db = start(sqlite.memory())
  let assert Ok(id) = insert(db, "ada@example.com")
  let assert Ok(user) =
    sql.query("select * from users where id = ")
    |> sql.arg(sql.Int(id))
    |> sql.returning(user_decoder())
    |> pool.one(db, _)
  assert user
    == User(
      id:,
      email: "ada@example.com",
      active: False,
      joined: Some(timestamp.from_unix_seconds_and_nanoseconds(
        1_700_000_000,
        250_000_000,
      )),
      born: calendar.Date(1990, calendar.March, 2),
      wakes: calendar.TimeOfDay(6, 30, 0, 0),
      avatar: <<0, 1, 255>>,
      score: 9.5,
    )
  pool.shutdown(db)
}

pub fn affected_rows_and_nulls_test() {
  let db = start(sqlite.memory())
  let assert Ok(_) = insert(db, "a@x")
  let assert Ok(_) = insert(db, "b@x")
  assert pool.exec(db, sql.query("update users set joined = null")) == Ok(2)
  assert sql.query("select joined from users")
    |> sql.returning(decode.at([0], decode.optional(sql.timestamp_decoder())))
    |> pool.all(db, _)
    == Ok([None, None])
  pool.shutdown(db)
}

pub fn constraint_errors_are_typed_test() {
  let db = start(sqlite.memory())
  let assert Ok(id) = insert(db, "a@x")
  let assert Error(sql.UniqueViolation(constraint: "users.email", ..)) =
    insert(db, "a@x")
  let post = fn(user, likes) {
    sql.query("insert into posts (user_id, likes) values (?1, ?2)")
    |> sql.bind(sql.Int(user))
    |> sql.bind(sql.Int(likes))
    |> pool.exec(db, _)
  }
  let assert Ok(1) = post(id, 1)
  let assert Error(sql.ForeignKeyViolation(..)) = post(id + 100, 1)
  let assert Error(sql.CheckViolation(..)) = post(id, -1)
  let assert Error(sql.NotNullViolation(column: "users.email", ..)) =
    pool.exec(db, sql.query("insert into users (email) values (null)"))
  let assert Error(sql.QueryFailed(..)) =
    pool.exec(db, sql.query("select * from missing"))
  let assert Error(sql.QueryFailed(code: "unsupported", ..)) =
    sql.query("select ?1") |> sql.bind(sql.Array([])) |> pool.exec(db, _)
  pool.shutdown(db)
}

pub fn transactions_and_savepoints_test() {
  let db = start(sqlite.memory())
  let count = fn() {
    sql.query("select count(*) from users")
    |> sql.returning(decode.at([0], decode.int))
    |> pool.one(db, _)
  }
  let assert Ok(_) =
    pool.transaction(db, fn(tx) {
      let assert Ok(_) = insert(tx, "kept@x")
      // An inner transaction is a savepoint: its rollback keeps the outer.
      let _ =
        pool.transaction(tx, fn(inner) {
          let assert Ok(_) = insert(inner, "dropped@x")
          Error("undo")
        })
      Ok(Nil)
    })
  assert count() == Ok(1)
  let assert Error(sql.RolledBack("no")) =
    pool.transaction(db, fn(tx) {
      let assert Ok(_) = insert(tx, "gone@x")
      Error("no")
    })
  assert count() == Ok(1)
  pool.shutdown(db)
}

pub fn file_databases_persist_test() {
  let path = "build/test-sqlite-" <> int.to_string(unique()) <> ".db"
  let db = start(sqlite.file(path))
  let assert Ok(_) = insert(db, "ada@x")
  assert sql.query("pragma journal_mode")
    |> sql.returning(decode.at([0], decode.string))
    |> pool.one(db, _)
    == Ok("wal")
  pool.shutdown(db)

  let db = start(sqlite.file(path))
  assert sql.query("select email from users")
    |> sql.returning(decode.at([0], decode.string))
    |> pool.all(db, _)
    == Ok(["ada@x"])
  pool.shutdown(db)
}

pub fn slow_statements_time_out_test() {
  let assert Ok(db) =
    pool.new(sqlite.driver(sqlite.memory()))
    |> pool.query_timeout(duration.milliseconds(100))
    |> pool.start
  let forever =
    "with recursive n(i) as (select 1 union all select i + 1 from n)
     select count(*) from n"
  assert pool.exec(db, sql.query(forever)) == Error(sql.QueryTimeout)
  // The pool replaces the closed connection.
  assert sql.query("select 41 + 1")
    |> sql.returning(decode.at([0], decode.int))
    |> pool.one(db, _)
    |> result.is_ok
  pool.shutdown(db)
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn unique() -> Int {
  int.absolute_value(unique_integer())
}

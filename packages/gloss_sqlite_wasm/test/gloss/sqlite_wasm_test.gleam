import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import gleam/time/timestamp
import gloss/sql
import gloss/sql_async.{type Database}
import gloss/sqlite_wasm

const schema =
  "
  create table users (
    id integer primary key,
    email text not null unique,
    active boolean not null default 1,
    joined timestamp,
    born date,
    wakes time,
    avatar blob,
    score real
  );
  create table posts (
    id integer primary key,
    user_id integer not null references users (id),
    likes integer not null check (likes >= 0)
  );"

fn with_db(test_: fn(Database) -> Promise(Nil)) -> Promise(Nil) {
  use opened <- promise.await(sqlite_wasm.open(sqlite_wasm.memory()))
  let assert Ok(db) = opened
  use created <- promise.await(sql_async.script(db, schema))
  let assert Ok(Nil) = created
  use _ <- promise.await(test_(db))
  sql_async.close(db)
}

type User {
  User(
    email: String,
    active: Bool,
    joined: Option(timestamp.Timestamp),
    born: calendar.Date,
    wakes: calendar.TimeOfDay,
    avatar: BitArray,
    score: Float,
  )
}

const joined = 1_700_000_000

fn insert(db: Database, email: String) -> Promise(Result(Int, sql.Error)) {
  sql.query(
    "insert into users (email, active, joined, born, wakes, avatar, score)
     values (?1, ?2, ?3, ?4, ?5, ?6, ?7) returning id",
  )
  |> sql.bind(sql.Text(email))
  |> sql.bind(sql.Bool(False))
  |> sql.bind(sql.Timestamp(timestamp.from_unix_seconds(joined)))
  |> sql.bind(sql.Date(calendar.Date(1990, calendar.March, 2)))
  |> sql.bind(sql.Time(calendar.TimeOfDay(6, 30, 0, 0)))
  |> sql.bind(sql.Bytes(<<0, 1, 255>>))
  |> sql.bind(sql.Float(9.5))
  |> sql.returning(decode.at([0], decode.int))
  |> sql_async.one(db, _)
}

pub fn values_round_trip_test() -> Promise(Nil) {
  use db <- with_db
  use id <- promise.await(insert(db, "ada@example.com"))
  let assert Ok(id) = id
  use user <- promise.await(
    sql.query("select email, active, joined, born, wakes, avatar, score")
    |> sql.append(" from users where id = ")
    |> sql.arg(sql.Int(id))
    |> sql.returning({
      use email <- decode.field(0, decode.string)
      use active <- decode.field(1, decode.bool)
      use joined <- decode.field(2, decode.optional(sql.timestamp_decoder()))
      use born <- decode.field(3, sql.date_decoder())
      use wakes <- decode.field(4, sql.time_decoder())
      use avatar <- decode.field(5, decode.bit_array)
      use score <- decode.field(6, decode.float)
      decode.success(User(
        email:,
        active:,
        joined:,
        born:,
        wakes:,
        avatar:,
        score:,
      ))
    })
    |> sql_async.one(db, _),
  )
  assert user
    == Ok(User(
      email: "ada@example.com",
      active: False,
      joined: Some(timestamp.from_unix_seconds(joined)),
      born: calendar.Date(1990, calendar.March, 2),
      wakes: calendar.TimeOfDay(6, 30, 0, 0),
      avatar: <<0, 1, 255>>,
      score: 9.5,
    ))
  promise.resolve(Nil)
}

pub fn affected_rows_and_nulls_test() -> Promise(Nil) {
  use db <- with_db
  use _ <- promise.await(insert(db, "a@x"))
  use _ <- promise.await(insert(db, "b@x"))
  use updated <- promise.await(sql_async.exec(
    db,
    sql.query("update users set joined = null"),
  ))
  assert updated == Ok(2)
  use joined <- promise.await(
    sql.query("select joined from users")
    |> sql.returning(decode.at([0], decode.optional(sql.timestamp_decoder())))
    |> sql_async.all(db, _),
  )
  assert joined == Ok([None, None])
  promise.resolve(Nil)
}

pub fn constraint_errors_are_typed_test() -> Promise(Nil) {
  use db <- with_db
  use first <- promise.await(insert(db, "a@x"))
  let assert Ok(id) = first
  use again <- promise.await(insert(db, "a@x"))
  let assert Error(sql.UniqueViolation(constraint: "users.email", ..)) = again
  let post = fn(user, likes) {
    sql.query("insert into posts (user_id, likes) values (?1, ?2)")
    |> sql.bind(sql.Int(user))
    |> sql.bind(sql.Int(likes))
    |> sql_async.exec(db, _)
  }
  use orphan <- promise.await(post(id + 100, 1))
  let assert Error(sql.ForeignKeyViolation(..)) = orphan
  use negative <- promise.await(post(id, -1))
  let assert Error(sql.CheckViolation(..)) = negative
  use missing <- promise.await(sql_async.exec(
    db,
    sql.query("select * from nope"),
  ))
  let assert Error(sql.QueryFailed(..)) = missing
  promise.resolve(Nil)
}

pub fn transactions_roll_back_test() -> Promise(Nil) {
  use db <- with_db
  use result <- promise.await(
    sql_async.transaction(db, fn(tx) {
      use _ <- promise.try_await(insert(tx, "kept@x"))
      use inner <- promise.await(
        sql_async.transaction(tx, fn(inner) {
          use _ <- promise.await(insert(inner, "dropped@x"))
          promise.resolve(Error("undo"))
        }),
      )
      assert inner == Error(sql.RolledBack("undo"))
      promise.resolve(Ok(Nil))
    }),
  )
  assert result == Ok(Nil)
  use emails <- promise.await(
    sql.query("select email from users")
    |> sql.returning(decode.at([0], decode.string))
    |> sql_async.all(db, _),
  )
  assert emails == Ok(["kept@x"])
  promise.resolve(Nil)
}

pub fn opfs_is_refused_outside_a_browser_test() -> Promise(Nil) {
  use opened <- promise.await(sqlite_wasm.open(sqlite_wasm.opfs("app.db")))
  let assert Error(sql.ConnectionFailed(_)) = opened
  promise.resolve(Nil)
}

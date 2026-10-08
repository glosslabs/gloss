import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import gleam/time/timestamp
import gloss/pglite
import gloss/sql
import gloss/sql/async.{type Database}

const schema =
  "
  create table users (
    id serial primary key,
    email text not null unique,
    active boolean not null default true,
    joined timestamptz,
    born date,
    wakes time,
    avatar bytea,
    score float8,
    balance numeric,
    tags text[],
    big int8
  );
  create table posts (
    id serial primary key,
    user_id int not null references users (id),
    likes int not null check (likes >= 0)
  );"

fn with_db(test_: fn(Database) -> Promise(Nil)) -> Promise(Nil) {
  use opened <- promise.await(pglite.open(pglite.memory()))
  let assert Ok(db) = opened
  use created <- promise.await(async.script(db, schema))
  let assert Ok(Nil) = created
  use _ <- promise.await(test_(db))
  async.close(db)
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
    balance: String,
    tags: List(String),
    big: Int,
  )
}

const joined = 1_700_000_000

fn insert(db: Database, email: String) -> Promise(Result(Int, sql.Error)) {
  sql.query(
    "insert into users
       (email, active, joined, born, wakes, avatar, score, balance, tags, big)
     values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) returning id",
  )
  |> sql.bind(sql.Text(email))
  |> sql.bind(sql.Bool(False))
  |> sql.bind(
    sql.Timestamp(timestamp.from_unix_seconds_and_nanoseconds(
      joined,
      123_456_000,
    )),
  )
  |> sql.bind(sql.Date(calendar.Date(1990, calendar.March, 2)))
  |> sql.bind(sql.Time(calendar.TimeOfDay(6, 30, 0, 250_000_000)))
  |> sql.bind(sql.Bytes(<<0, 1, 255>>))
  |> sql.bind(sql.Float(9.5))
  |> sql.bind(sql.Text("10.25"))
  |> sql.bind(sql.Array([sql.Text("x"), sql.Text("y z")]))
  |> sql.bind(sql.Int(9_007_199_254_740_991))
  |> sql.returning(decode.at([0], decode.int))
  |> async.one(db, _)
}

pub fn values_round_trip_like_gloss_pg_test() -> Promise(Nil) {
  use db <- with_db
  use id <- promise.await(insert(db, "ada@example.com"))
  let assert Ok(id) = id
  use user <- promise.await(
    sql.query(
      "select email, active, joined, born, wakes, avatar, score, balance, tags, big
       from users where id = $1",
    )
    |> sql.bind(sql.Int(id))
    |> sql.returning({
      use email <- decode.field(0, decode.string)
      use active <- decode.field(1, decode.bool)
      use joined <- decode.field(2, decode.optional(sql.timestamp_decoder()))
      use born <- decode.field(3, sql.date_decoder())
      use wakes <- decode.field(4, sql.time_decoder())
      use avatar <- decode.field(5, decode.bit_array)
      use score <- decode.field(6, decode.float)
      use balance <- decode.field(7, decode.string)
      use tags <- decode.field(8, decode.list(decode.string))
      use big <- decode.field(9, decode.int)
      decode.success(User(
        email:,
        active:,
        joined:,
        born:,
        wakes:,
        avatar:,
        score:,
        balance:,
        tags:,
        big:,
      ))
    })
    |> async.one(db, _),
  )
  assert user
    == Ok(User(
      email: "ada@example.com",
      active: False,
      // Microseconds survive, as they do with gloss/pg.
      joined: Some(timestamp.from_unix_seconds_and_nanoseconds(
        joined,
        123_456_000,
      )),
      born: calendar.Date(1990, calendar.March, 2),
      wakes: calendar.TimeOfDay(6, 30, 0, 250_000_000),
      avatar: <<0, 1, 255>>,
      score: 9.5,
      balance: "10.25",
      tags: ["x", "y z"],
      big: 9_007_199_254_740_991,
    ))
  promise.resolve(Nil)
}

pub fn affected_rows_and_nulls_test() -> Promise(Nil) {
  use db <- with_db
  use _ <- promise.await(insert(db, "a@x"))
  use _ <- promise.await(insert(db, "b@x"))
  use updated <- promise.await(async.exec(
    db,
    sql.query("update users set joined = null"),
  ))
  assert updated == Ok(2)
  use joined <- promise.await(
    sql.query("select joined from users")
    |> sql.returning(decode.at([0], decode.optional(sql.timestamp_decoder())))
    |> async.all(db, _),
  )
  assert joined == Ok([None, None])
  promise.resolve(Nil)
}

pub fn constraint_errors_are_typed_test() -> Promise(Nil) {
  use db <- with_db
  use first <- promise.await(insert(db, "a@x"))
  let assert Ok(id) = first
  use again <- promise.await(insert(db, "a@x"))
  let assert Error(sql.UniqueViolation(constraint: "users_email_key", ..)) =
    again
  let post = fn(user, likes) {
    sql.query("insert into posts (user_id, likes) values ($1, $2)")
    |> sql.bind(sql.Int(user))
    |> sql.bind(sql.Int(likes))
    |> async.exec(db, _)
  }
  use orphan <- promise.await(post(id + 100, 1))
  let assert Error(sql.ForeignKeyViolation(constraint: "posts_user_id_fkey", ..)) =
    orphan
  use negative <- promise.await(post(id, -1))
  let assert Error(sql.CheckViolation(constraint: "posts_likes_check", ..)) =
    negative
  use null <- promise.await(async.exec(
    db,
    sql.query("insert into users (email) values (null)"),
  ))
  let assert Error(sql.NotNullViolation(column: "email", ..)) = null
  use missing <- promise.await(async.exec(db, sql.query("select * from nope")))
  let assert Error(sql.QueryFailed(code: "42P01", ..)) = missing
  promise.resolve(Nil)
}

pub fn transactions_and_savepoints_test() -> Promise(Nil) {
  use db <- with_db
  use result <- promise.await(
    async.transaction(db, fn(tx) {
      use _ <- promise.try_await(insert(tx, "kept@x"))
      use inner <- promise.await(
        async.transaction(tx, fn(inner) {
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
    |> async.all(db, _),
  )
  assert emails == Ok(["kept@x"])
  promise.resolve(Nil)
}

pub fn types_made_later_are_read_as_text_test() -> Promise(Nil) {
  use db <- with_db
  use _ <- promise.await(async.script(
    db,
    "create type mood as enum ('happy', 'sad');
     create table moods (m mood, ms mood[]);
     insert into moods values ('happy', '{happy,sad}');",
  ))
  use moods <- promise.await(
    sql.query("select m, ms from moods")
    |> sql.returning({
      use m <- decode.field(0, decode.string)
      use ms <- decode.field(1, decode.string)
      decode.success(#(m, ms))
    })
    |> async.one(db, _),
  )
  assert moods == Ok(#("happy", "{happy,sad}"))
  promise.resolve(Nil)
}

pub fn directories_persist_test() -> Promise(Nil) {
  let dir = "build/test-pglite-" <> int.to_string(unique())
  use opened <- promise.await(pglite.open(pglite.directory(dir)))
  let assert Ok(db) = opened
  use _ <- promise.await(async.script(
    db,
    "create table kept (n int); insert into kept values (42);",
  ))
  use _ <- promise.await(async.close(db))
  use opened <- promise.await(pglite.open(pglite.directory(dir)))
  let assert Ok(db) = opened
  use kept <- promise.await(
    sql.query("select n from kept")
    |> sql.returning(decode.at([0], decode.int))
    |> async.one(db, _),
  )
  assert kept == Ok(42)
  async.close(db)
}

@external(javascript, "../pglite_test_ffi.mjs", "unique")
fn unique() -> Int

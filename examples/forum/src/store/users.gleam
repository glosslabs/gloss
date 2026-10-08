//// The user store, answered from Postgres.

import domain/accounts/user.{type User, User}
import domain/accounts/user_store.{
  type Insertion, type Message, type NewUser, DuplicateEmail, FindByEmail, Get,
  GetMany, Insert, Inserted, Save,
}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gloss/sql
import gloss/sql/pool
import gloss/store.{type Store}

/// The store. It answers in the calling process, so the caller borrows the
/// pool connection and results are never copied between processes.
pub fn new(db: pool.Db) -> Store(Message) {
  store.inline(fn(message) {
    case message {
      Insert(user:, reply:) -> insert(db, user) |> store.reply(reply)
      Get(id:, reply:) -> get(db, id) |> store.reply(reply)
      GetMany(ids:, reply:) -> get_many(db, ids) |> store.reply(reply)
      FindByEmail(email:, reply:) ->
        find_by_email(db, email) |> store.reply(reply)
      Save(user:, reply:) -> save(db, user) |> store.reply(reply)
    }
  })
}

fn insert(db: pool.Db, new: NewUser) -> Result(Insertion, sql.Error) {
  let inserted =
    sql.query("insert into users (email, display_name, password_hash, joined_at)
       values ($1, $2, $3, $4) returning " <> columns)
    |> sql.bind(sql.Text(new.email))
    |> sql.bind(sql.Text(new.display_name))
    |> sql.bind(sql.Text(new.password_hash))
    |> sql.bind(sql.Timestamp(new.joined_at))
    |> sql.returning(user_decoder())
    |> sql.label("users.insert")
    |> pool.one(db, _)
  case inserted {
    Ok(user) -> Ok(Inserted(user))
    Error(sql.UniqueViolation(constraint: "users_email_key", ..)) ->
      Ok(DuplicateEmail)
    Error(error) -> Error(error)
  }
}

fn get(db: pool.Db, id: Int) -> Result(Option(User), sql.Error) {
  select("where id = $1")
  |> sql.bind(sql.Int(id))
  |> sql.label("users.get")
  |> pool.optional(db, _)
}

fn get_many(db: pool.Db, ids: List(Int)) -> Result(List(User), sql.Error) {
  select("where id = any($1)")
  |> sql.bind(sql.Array(list.map(ids, sql.Int)))
  |> sql.label("users.get_many")
  |> pool.all(db, _)
}

fn find_by_email(
  db: pool.Db,
  email: String,
) -> Result(Option(User), sql.Error) {
  select("where email = $1")
  |> sql.bind(sql.Text(email))
  |> sql.label("users.find_by_email")
  |> pool.optional(db, _)
}

fn save(db: pool.Db, user: User) -> Result(Nil, sql.Error) {
  sql.query(
    "update users
     set email = $2, display_name = $3, bio = $4, avatar = $5,
         password_hash = $6
     where id = $1",
  )
  |> sql.bind(sql.Int(user.id))
  |> sql.bind(sql.Text(user.email))
  |> sql.bind(sql.Text(user.display_name))
  |> sql.bind(sql.Text(user.bio))
  |> sql.bind(sql.nullable(user.avatar, sql.Text))
  |> sql.bind(sql.Text(user.password_hash))
  |> sql.label("users.save")
  |> pool.exec(db, _)
  |> result.replace(Nil)
}

const columns = "id, email, display_name, bio, avatar, password_hash, joined_at"

fn select(where: String) -> sql.Statement(User) {
  sql.query("select " <> columns <> " from users " <> where)
  |> sql.returning(user_decoder())
}

fn user_decoder() -> decode.Decoder(User) {
  use id <- decode.field(0, decode.int)
  use email <- decode.field(1, decode.string)
  use display_name <- decode.field(2, decode.string)
  use bio <- decode.field(3, decode.string)
  use avatar <- decode.field(4, decode.optional(decode.string))
  use password_hash <- decode.field(5, decode.string)
  use joined_at <- decode.field(6, sql.timestamp_decoder())
  decode.success(User(
    id:,
    email:,
    display_name:,
    bio:,
    avatar:,
    password_hash:,
    joined_at:,
  ))
}

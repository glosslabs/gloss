//// The user store, answered from Postgres.

import domain/accounts/user.{type User, User}
import domain/accounts/user_store.{
  type Insertion, type Message, type NewUser, DuplicateEmail, FindByEmail, Get,
  GetMany, Insert, Inserted, Save,
}
import gleam/option.{type Option}
import gleam/result
import gloss/sql
import gloss/sql/pool
import gloss/sql/query
import gloss/store.{type Store}
import store/schema/users

/// The store. It answers in the calling process, so the caller borrows the
/// pool connection and results are never copied between processes.
pub fn new(db: pool.Db) -> Store(Message) {
  store.inline(fn(message) {
    case message {
      Insert(user:, reply:) -> insert(db, user) |> pool.reply(reply)
      Get(id:, reply:) -> get(db, id) |> pool.reply(reply)
      GetMany(ids:, reply:) -> get_many(db, ids) |> pool.reply(reply)
      FindByEmail(email:, reply:) ->
        find_by_email(db, email) |> pool.reply(reply)
      Save(user:, reply:) -> save(db, user) |> pool.reply(reply)
    }
  })
}

fn insert(db: pool.Db, new: NewUser) -> Result(Insertion, sql.Error) {
  let inserted =
    query.insert(users.table(), [
      query.set(users.email(), new.email),
      query.set(users.display_name(), new.display_name),
      query.set(users.password_hash(), new.password_hash),
      query.set(users.joined_at(), new.joined_at),
    ])
    |> query.select(row())
    |> query.to_statement
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
  select()
  |> query.where(query.eq(users.id(), id))
  |> query.to_statement
  |> sql.label("users.get")
  |> pool.optional(db, _)
}

fn get_many(db: pool.Db, ids: List(Int)) -> Result(List(User), sql.Error) {
  select()
  |> query.where(query.in(users.id(), ids))
  |> query.to_statement
  |> sql.label("users.get_many")
  |> pool.all(db, _)
}

fn find_by_email(
  db: pool.Db,
  email: String,
) -> Result(Option(User), sql.Error) {
  select()
  |> query.where(query.eq(users.email(), email))
  |> query.to_statement
  |> sql.label("users.find_by_email")
  |> pool.optional(db, _)
}

fn save(db: pool.Db, user: User) -> Result(Nil, sql.Error) {
  query.update(users.table(), [
    query.set(users.email(), user.email),
    query.set(users.display_name(), user.display_name),
    query.set(users.bio(), user.bio),
    query.set(users.avatar(), user.avatar),
    query.set(users.password_hash(), user.password_hash),
  ])
  |> query.where(query.eq(users.id(), user.id))
  |> query.to_statement
  |> sql.label("users.save")
  |> pool.exec(db, _)
  |> result.replace(Nil)
}

fn select() -> query.Query(query.Filtered(query.Select), users.Users, User) {
  query.from(users.table()) |> query.select(row())
}

fn row() -> query.Selection(users.Users, User) {
  use id <- query.field(users.id())
  use email <- query.field(users.email())
  use display_name <- query.field(users.display_name())
  use bio <- query.field(users.bio())
  use avatar <- query.field(users.avatar())
  use password_hash <- query.field(users.password_hash())
  use joined_at <- query.field(users.joined_at())
  query.done(User(
    id:,
    email:,
    display_name:,
    bio:,
    avatar:,
    password_hash:,
    joined_at:,
  ))
}

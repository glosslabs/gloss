//// The user repository, answered from Postgres.

import domain/accounts/user.{type User, User}
import domain/accounts/user_repository.{
  type Message, type UserRepository, DuplicateEmail, FindByEmail, Get, GetMany,
  Insert, Inserted, Save,
}
import domain/repository.{type Unavailable, Unavailable}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/result
import gloss/sql

/// Start the repository. Each message is answered in a process of its own,
/// so statements run in parallel on the pool's connections.
pub fn start(db: sql.Db) -> Result(UserRepository, actor.StartError) {
  actor.new(db)
  |> actor.on_message(fn(db, message) {
    process.spawn_unlinked(fn() { answer(db, message) })
    actor.continue(db)
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn answer(db: sql.Db, message: Message) -> Nil {
  case message {
    Insert(user: new, reply:) ->
      process.send(
        reply,
        case
          sql.query(
            "insert into users (email, display_name, password_hash, joined_at)
           values ($1, $2, $3, $4) returning " <> columns,
          )
          |> sql.bind(sql.Text(new.email))
          |> sql.bind(sql.Text(new.display_name))
          |> sql.bind(sql.Text(new.password_hash))
          |> sql.bind(sql.Timestamp(new.joined_at))
          |> sql.returning(user_decoder())
          |> sql.label("users.insert")
          |> sql.one(db, _)
        {
          Ok(user) -> Ok(Inserted(user))
          Error(sql.UniqueViolation(constraint: "users_email_key", ..)) ->
            Ok(DuplicateEmail)
          Error(error) -> Error(unavailable(error))
        },
      )

    Get(id:, reply:) ->
      select("where id = $1")
      |> sql.bind(sql.Int(id))
      |> sql.label("users.get")
      |> sql.optional(db, _)
      |> respond(reply)

    GetMany(ids:, reply:) ->
      select("where id = any($1)")
      |> sql.bind(sql.Array(list.map(ids, sql.Int)))
      |> sql.label("users.get_many")
      |> sql.all(db, _)
      |> respond(reply)

    FindByEmail(email:, reply:) ->
      select("where email = $1")
      |> sql.bind(sql.Text(email))
      |> sql.label("users.find_by_email")
      |> sql.optional(db, _)
      |> respond(reply)

    Save(user:, reply:) ->
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
      |> sql.exec(db, _)
      |> result.replace(Nil)
      |> respond(reply)
  }
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

fn respond(
  result: Result(a, sql.Error),
  reply: process.Subject(Result(a, Unavailable)),
) -> Nil {
  process.send(reply, result.map_error(result, unavailable))
}

fn unavailable(error: sql.Error) -> Unavailable {
  Unavailable(sql.describe(error))
}

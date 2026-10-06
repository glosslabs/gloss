//// User accounts: registration, sign-in and profiles, kept in memory.

import domain/accounts/password
import domain/accounts/user.{
  type ProfileError, type RegisterError, type User, User,
}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/time/timestamp

pub opaque type Accounts {
  Accounts(subject: Subject(Message))
}

type State {
  State(next_id: Int, users: Dict(Int, User), by_email: Dict(String, Int))
}

type Message {
  Insert(
    email: String,
    hash: String,
    reply: Subject(Result(User, RegisterError)),
  )
  Get(id: Int, reply: Subject(Result(User, Nil)))
  FindByEmail(email: String, reply: Subject(Result(User, Nil)))
  Replace(user: User, reply: Subject(Nil))
}

pub fn start() -> Result(Accounts, actor.StartError) {
  actor.new(State(next_id: 1, users: dict.new(), by_email: dict.new()))
  |> actor.on_message(on_message)
  |> actor.start
  |> result.map(fn(started) { Accounts(started.data) })
}

/// Create an account. The password is hashed in the caller's process.
pub fn register(
  accounts: Accounts,
  email: String,
  password: String,
) -> Result(User, RegisterError) {
  use email <- result.try(user.email(email))
  use password <- result.try(user.password(password))
  let hash = password.hash(password)
  process.call(accounts.subject, 5000, Insert(email, hash, _))
}

/// The account with this email and password.
pub fn authenticate(
  accounts: Accounts,
  email: String,
  password: String,
) -> Result(User, Nil) {
  let found = case user.email(email) {
    Ok(email) -> process.call(accounts.subject, 5000, FindByEmail(email, _))
    Error(_) -> Error(Nil)
  }
  case found {
    Ok(user) ->
      case password.verify(password, user.password_hash) {
        True -> Ok(user)
        False -> Error(Nil)
      }
    Error(Nil) -> {
      // Take as long as a real check, so timing doesn't reveal accounts.
      let _ = password.verify(password, decoy)
      Error(Nil)
    }
  }
}

const decoy =
  "pbkdf2-sha256$100000$c2FsdHNhbHRzYWx0c2FsdA$ZGVjb3lkZWNveWRlY295ZGVjb3lkZWNveWRlY295ZGU"

pub fn get(accounts: Accounts, id: Int) -> Result(User, Nil) {
  process.call(accounts.subject, 5000, Get(id, _))
}

/// The users with these ids, by id. Unknown ids are left out.
pub fn many(accounts: Accounts, ids: List(Int)) -> Dict(Int, User) {
  ids
  |> list.unique
  |> list.filter_map(fn(id) {
    get(accounts, id) |> result.map(fn(u) { #(id, u) })
  })
  |> dict.from_list
}

pub fn update_profile(
  accounts: Accounts,
  id: Int,
  display_name: String,
  bio: String,
) -> Result(User, ProfileError) {
  use #(display_name, bio) <- result.try(user.profile(display_name, bio))
  case get(accounts, id) {
    Ok(found) -> {
      let updated = User(..found, display_name:, bio:)
      process.call(accounts.subject, 5000, Replace(updated, _))
      Ok(updated)
    }
    // A user that vanished mid-request: nothing to update.
    Error(Nil) -> Error(user.DisplayNameMissing)
  }
}

/// Set the user's avatar, returning the one it replaces.
pub fn set_avatar(
  accounts: Accounts,
  id: Int,
  avatar: String,
) -> Result(Option(String), Nil) {
  use found <- result.map(get(accounts, id))
  process.call(accounts.subject, 5000, Replace(
    User(..found, avatar: Some(avatar)),
    _,
  ))
  found.avatar
}

fn on_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Insert(email:, hash:, reply:) ->
      case dict.has_key(state.by_email, email) {
        True -> {
          process.send(reply, Error(user.EmailTaken))
          actor.continue(state)
        }
        False -> {
          let new =
            User(
              id: state.next_id,
              email:,
              display_name: user.default_name(email),
              bio: "",
              avatar: None,
              password_hash: hash,
              joined_at: timestamp.system_time(),
            )
          process.send(reply, Ok(new))
          actor.continue(State(
            next_id: state.next_id + 1,
            users: dict.insert(state.users, new.id, new),
            by_email: dict.insert(state.by_email, email, new.id),
          ))
        }
      }
    Get(id:, reply:) -> {
      process.send(reply, dict.get(state.users, id))
      actor.continue(state)
    }
    FindByEmail(email:, reply:) -> {
      process.send(
        reply,
        dict.get(state.by_email, email) |> result.try(dict.get(state.users, _)),
      )
      actor.continue(state)
    }
    Replace(user:, reply:) -> {
      process.send(reply, Nil)
      actor.continue(
        State(..state, users: dict.insert(state.users, user.id, user)),
      )
    }
  }
}

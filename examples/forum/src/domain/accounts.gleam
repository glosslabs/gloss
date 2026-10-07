//// User accounts: registration, sign-in and profiles.
////
//// The rules live here and in `domain/accounts/user`; storing users is the
//// `UserStore`'s job.

import domain/accounts/user.{
  type ProfileError, type RegisterError, type User, User,
}
import domain/accounts/user_store.{
  type UserStore, DuplicateEmail, Inserted, NewUser,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gloss/clock.{type Clock}
import gloss/password

pub opaque type Accounts {
  Accounts(users: UserStore, clock: Clock)
}

/// New accounts are stamped with the time from `clock`.
pub fn new(users: UserStore, clock: Clock) -> Accounts {
  Accounts(users:, clock:)
}

/// Create an account. The password is hashed in the caller's process.
pub fn register(
  accounts: Accounts,
  email: String,
  plain: String,
) -> Result(User, RegisterError) {
  use email <- result.try(user.email(email))
  use plain <- result.try(user.password(plain))
  let new =
    NewUser(
      email:,
      display_name: user.default_name(email),
      password_hash: password.hash(plain),
      joined_at: clock.now(accounts.clock),
    )
  case user_store.insert(accounts.users, new) {
    Inserted(user) -> Ok(user)
    DuplicateEmail -> Error(user.EmailTaken)
  }
}

/// The account with this email and password.
pub fn authenticate(
  accounts: Accounts,
  email: String,
  plain: String,
) -> Result(User, Nil) {
  let found = case user.email(email) {
    Ok(email) -> user_store.find_by_email(accounts.users, email)
    Error(_) -> None
  }
  case found {
    Some(user) ->
      case password.verify(plain, user.password_hash) {
        True -> Ok(user)
        False -> Error(Nil)
      }
    None -> {
      // Take as long as a real check, so timing doesn't reveal accounts.
      let _ = password.verify(plain, decoy)
      Error(Nil)
    }
  }
}

const decoy =
  "pbkdf2-sha256$100000$c2FsdHNhbHRzYWx0c2FsdA$ZGVjb3lkZWNveWRlY295ZGVjb3lkZWNveWRlY295ZGU"

pub fn get(accounts: Accounts, id: Int) -> Result(User, Nil) {
  user_store.get(accounts.users, id) |> option.to_result(Nil)
}

/// The users with these ids, by id. Unknown ids are left out.
pub fn many(accounts: Accounts, ids: List(Int)) -> Dict(Int, User) {
  user_store.get_many(accounts.users, list.unique(ids))
  |> list.map(fn(user) { #(user.id, user) })
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
      user_store.save(accounts.users, updated)
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
  user_store.save(accounts.users, User(..found, avatar: Some(avatar)))
  found.avatar
}

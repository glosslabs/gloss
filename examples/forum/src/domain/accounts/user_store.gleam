//// The port for storing users: the messages a user store answers.

import domain/accounts/user.{type User}
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}
import gloss/store.{type Reply, type Store}

pub type UserStore =
  Store(Message)

/// A user not stored yet, so without an id.
pub type NewUser {
  NewUser(
    email: String,
    display_name: String,
    password_hash: String,
    joined_at: Timestamp,
  )
}

pub type Insertion {
  Inserted(User)
  /// Another user has this email.
  DuplicateEmail
}

pub type Message {
  Insert(user: NewUser, reply: Reply(Insertion))
  Get(id: Int, reply: Reply(Option(User)))
  /// The users with these ids. Unknown ids are left out.
  GetMany(ids: List(Int), reply: Reply(List(User)))
  /// `email` is already normalised by `user.email`.
  FindByEmail(email: String, reply: Reply(Option(User)))
  /// Store every field of an existing user.
  Save(user: User, reply: Reply(Nil))
}

pub fn insert(users: UserStore, user: NewUser) -> Insertion {
  store.call(users, Insert(user, _))
}

pub fn get(users: UserStore, id: Int) -> Option(User) {
  store.call(users, Get(id, _))
}

pub fn get_many(users: UserStore, ids: List(Int)) -> List(User) {
  store.call(users, GetMany(ids, _))
}

pub fn find_by_email(users: UserStore, email: String) -> Option(User) {
  store.call(users, FindByEmail(email, _))
}

pub fn save(users: UserStore, user: User) -> Nil {
  store.call(users, Save(user, _))
}

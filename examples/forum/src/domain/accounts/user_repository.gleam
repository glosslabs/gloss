//// The port for storing users: the messages a user repository answers.

import domain/accounts/user.{type User}
import domain/repository.{type Reply}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}

pub type UserRepository =
  Subject(Message)

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

pub fn insert(users: UserRepository, user: NewUser) -> Insertion {
  repository.call(users, Insert(user, _))
}

pub fn get(users: UserRepository, id: Int) -> Option(User) {
  repository.call(users, Get(id, _))
}

pub fn get_many(users: UserRepository, ids: List(Int)) -> List(User) {
  repository.call(users, GetMany(ids, _))
}

pub fn find_by_email(users: UserRepository, email: String) -> Option(User) {
  repository.call(users, FindByEmail(email, _))
}

pub fn save(users: UserRepository, user: User) -> Nil {
  repository.call(users, Save(user, _))
}

//// The store contract, against each adapter. The Postgres adapters
//// run when TEST_DATABASE_URL is set; their tables are emptied first.

import domain/accounts/user_store.{Inserted, NewUser}
import envoy
import gleam/time/timestamp
import gloss/sql
import gloss/store
import gloss/tracer
import infra/db
import store/thread_store as postgres_threads
import store/user_store as postgres_users
import support/memory_threads
import support/memory_users
import support/store_contract as contract

pub fn memory_users_test() {
  contract.users(memory_users.start())
}

pub fn memory_threads_test() {
  contract.threads(memory_threads.start(), 1, 2)
}

pub fn postgres_users_test() {
  use db <- with_database
  let assert Ok(users) = postgres_users.new(db) |> store.start
  contract.users(users)
}

pub fn postgres_threads_test() {
  use db <- with_database
  let assert Ok(users) = postgres_users.new(db) |> store.start
  let assert Ok(threads) = postgres_threads.new(db) |> store.start
  // Posts reference real users.
  let author = user(users, "author@x")
  let other = user(users, "other@x")
  contract.threads(threads, author, other)
}

fn user(users, email) -> Int {
  let assert Inserted(user) =
    user_store.insert(
      users,
      NewUser(
        email:,
        display_name: "",
        password_hash: "",
        joined_at: timestamp.system_time(),
      ),
    )
  user.id
}

fn with_database(test_: fn(sql.Db) -> Nil) -> Nil {
  case envoy.get("TEST_DATABASE_URL") {
    Error(Nil) -> Nil
    Ok(url) -> {
      let assert Ok(db) = db.start(url, tracer.new())
      let assert Ok(Nil) =
        sql.script(
          db,
          "truncate posts, threads, users restart identity cascade",
        )
      test_(db)
      sql.shutdown(db)
    }
  }
}

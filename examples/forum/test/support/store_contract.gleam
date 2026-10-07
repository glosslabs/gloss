//// What every user and thread store must do, whichever storage answers
//// it. `test/infra/store_test.gleam` runs these against the
//// in-memory adapters and, when a database is available, against Postgres.

import domain/accounts/user.{User}
import domain/accounts/user_store.{
  type UserStore, DuplicateEmail, Inserted, NewUser,
}
import domain/forum/thread
import domain/forum/thread_store.{type ThreadStore, NewPost, NewThread}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/time/timestamp

fn at(seconds: Int) -> timestamp.Timestamp {
  timestamp.from_unix_seconds(1_800_000_000 + seconds)
}

fn new_user(email: String) {
  NewUser(email:, display_name: "name", password_hash: "hash", joined_at: at(0))
}

pub fn users(users: UserStore) -> Nil {
  let assert Inserted(ada) = user_store.insert(users, new_user("ada@x"))
  assert ada.email == "ada@x"
  assert ada.joined_at == at(0)
  assert ada.avatar == None
  assert user_store.insert(users, new_user("ada@x")) == DuplicateEmail
  let assert Inserted(bob) = user_store.insert(users, new_user("bob@x"))

  assert user_store.get(users, ada.id) == Some(ada)
  assert user_store.get(users, -1) == None
  assert user_store.find_by_email(users, "bob@x") == Some(bob)
  assert user_store.find_by_email(users, "nobody@x") == None
  assert user_store.get_many(users, [bob.id, -1, ada.id])
    |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
    == [ada, bob]

  let updated =
    User(..ada, display_name: "Ada", bio: "hi", avatar: Some("a.png"))
  user_store.save(users, updated)
  assert user_store.get(users, ada.id) == Some(updated)
}

pub fn threads(threads: ThreadStore, author: Int, other: Int) -> Nil {
  let first =
    thread_store.open(
      threads,
      NewThread(title: "First", author_id: author, body: "one", at: at(1)),
    )
  assert first.title == "First"
  assert thread.author_id(first) == author
  assert first.last_activity == at(1)

  let second =
    thread_store.open(
      threads,
      NewThread(title: "Second", author_id: author, body: "two", at: at(2)),
    )
  assert thread_store.recent(threads, 0, 10)
    |> list.map(fn(t) { t.id })
    == [second.id, first.id]

  let assert Some(replied) =
    thread_store.add_post(
      threads,
      NewPost(thread_id: first.id, author_id: other, body: "reply", at: at(3)),
    )
  assert list.map(replied.posts, fn(p) { p.body }) == ["one", "reply"]
  assert replied.last_activity == at(3)
  assert thread_store.get(threads, first.id) == Some(replied)

  // A reply moves the thread to the front.
  assert thread_store.recent(threads, 0, 1) == [replied]
  assert thread_store.recent(threads, 1, 10)
    |> list.map(fn(t) { t.id })
    == [second.id]

  assert thread_store.add_post(
      threads,
      NewPost(thread_id: -1, author_id: other, body: "x", at: at(4)),
    )
    == None
  assert thread_store.get(threads, -1) == None
}

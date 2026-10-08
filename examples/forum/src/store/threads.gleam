//// The thread store, answered from Postgres.

import domain/forum/thread.{type Post, type Thread, Post, Thread}
import domain/forum/thread_store.{
  type Message, type NewPost, type NewThread, AddPost, Get, Open, Recent,
}
import gleam/dict
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import gloss/sql
import gloss/sql/pool
import gloss/sql/query
import gloss/store.{type Store}
import store/schema/posts
import store/schema/threads

/// The store. It answers in the calling process, so the caller borrows the
/// pool connection and results are never copied between processes.
pub fn new(db: pool.Db) -> Store(Message) {
  store.inline(fn(message) {
    case message {
      Open(thread:, reply:) -> open(db, thread) |> pool.reply(reply)
      AddPost(post:, reply:) -> add_post(db, post) |> pool.reply(reply)
      Get(id:, reply:) -> get(db, id) |> pool.reply(reply)
      Recent(offset:, limit:, reply:) ->
        recent(db, offset, limit) |> pool.reply(reply)
    }
  })
}

fn open(db: pool.Db, new: NewThread) -> Result(Thread, sql.Error) {
  use id <- result.try(
    pool.transaction(db, fn(tx) {
      use id <- result.try(
        query.insert(threads.table(), [
          query.set(threads.title(), new.title),
          query.set(threads.last_activity(), new.at),
        ])
        |> query.select(query.only(threads.id()))
        |> query.to_statement
        |> sql.label("threads.open")
        |> pool.one(tx, _),
      )
      use _ <- result.map(insert_post(tx, id, new.author_id, new.body, new.at))
      id
    })
    |> sql.flatten,
  )
  get(db, id) |> result.try(option.to_result(_, sql.NotFound))
}

fn add_post(db: pool.Db, new: NewPost) -> Result(Option(Thread), sql.Error) {
  let added =
    pool.transaction(db, fn(tx) {
      use touched <- result.try(
        query.update(threads.table(), [
          query.set(threads.last_activity(), new.at),
        ])
        |> query.where(query.eq(threads.id(), new.thread_id))
        |> query.to_statement
        |> sql.label("threads.touch")
        |> pool.exec(tx, _),
      )
      case touched {
        0 -> Ok(False)
        _ ->
          insert_post(tx, new.thread_id, new.author_id, new.body, new.at)
          |> result.replace(True)
      }
    })
  case sql.flatten(added) {
    Ok(True) -> get(db, new.thread_id)
    Ok(False) -> Ok(None)
    Error(error) -> Error(error)
  }
}

fn insert_post(
  tx: pool.Db,
  thread_id: Int,
  author_id: Int,
  body: String,
  at: Timestamp,
) -> Result(Int, sql.Error) {
  query.insert(posts.table(), [
    query.set(posts.thread_id(), thread_id),
    query.set(posts.author_id(), author_id),
    query.set(posts.body(), body),
    query.set(posts.at(), at),
  ])
  |> query.to_statement
  |> sql.label("posts.insert")
  |> pool.exec(tx, _)
}

fn get(db: pool.Db, id: Int) -> Result(Option(Thread), sql.Error) {
  select_threads()
  |> query.where(query.eq(threads.id(), id))
  |> query.to_statement
  |> sql.label("threads.get")
  |> with_posts(db, _)
  |> result.map(fn(threads) { list.first(threads) |> option.from_result })
}

fn recent(
  db: pool.Db,
  offset: Int,
  limit: Int,
) -> Result(List(Thread), sql.Error) {
  select_threads()
  |> query.order_by(threads.last_activity(), query.Desc)
  |> query.order_by(threads.id(), query.Desc)
  |> query.limit(limit)
  |> query.offset(offset)
  |> query.to_statement
  |> sql.label("threads.recent")
  |> with_posts(db, _)
}

/// A thread row, before its posts are attached.
type Row {
  Row(id: Int, title: String, last_activity: Timestamp)
}

fn select_threads() -> query.Query(
  query.Filtered(query.Select),
  threads.Threads,
  Row,
) {
  query.from(threads.table())
  |> query.select({
    use id <- query.field(threads.id())
    use title <- query.field(threads.title())
    use last_activity <- query.field(threads.last_activity())
    query.done(Row(id:, title:, last_activity:))
  })
}

/// Run the thread query, then load every thread's posts in one more query.
fn with_posts(
  db: pool.Db,
  threads: sql.Statement(Row),
) -> Result(List(Thread), sql.Error) {
  use rows <- result.try(pool.all(db, threads))
  use found <- result.map(case rows {
    [] -> Ok([])
    _ ->
      query.from(posts.table())
      |> query.where(query.in(
        posts.thread_id(),
        list.map(rows, fn(row) { row.id }),
      ))
      |> query.order_by(posts.id(), query.Asc)
      |> query.select({
        use thread_id <- query.field(posts.thread_id())
        use id <- query.field(posts.id())
        use author_id <- query.field(posts.author_id())
        use body <- query.field(posts.body())
        use at <- query.field(posts.at())
        query.done(#(thread_id, Post(id:, author_id:, body:, at:)))
      })
      |> query.to_statement
      |> sql.label("posts.for_threads")
      |> pool.all(db, _)
  })
  let by_thread = list.group(found, fn(pair) { pair.0 })
  list.map(rows, fn(row) {
    let thread_posts: List(Post) =
      dict.get(by_thread, row.id)
      |> result.unwrap([])
      |> list.reverse
      |> list.map(fn(pair) { pair.1 })
    Thread(
      id: row.id,
      title: row.title,
      posts: thread_posts,
      last_activity: row.last_activity,
    )
  })
}

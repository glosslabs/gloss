//// The thread store, answered from Postgres.

import domain/forum/thread.{type Post, type Thread, Post, Thread}
import domain/forum/thread_store.{
  type Message, type NewPost, type NewThread, AddPost, Get, Open, Recent,
}
import gleam/dict
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import gloss/sql
import gloss/sql/pool
import gloss/store.{type Store}

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
        sql.query(
          "insert into threads (title, last_activity) values ($1, $2)
           returning id",
        )
        |> sql.bind(sql.Text(new.title))
        |> sql.bind(sql.Timestamp(new.at))
        |> sql.returning(decode.at([0], decode.int))
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
        sql.query("update threads set last_activity = $2 where id = $1")
        |> sql.bind(sql.Int(new.thread_id))
        |> sql.bind(sql.Timestamp(new.at))
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
  sql.query(
    "insert into posts (thread_id, author_id, body, at) values ($1, $2, $3, $4)",
  )
  |> sql.bind(sql.Int(thread_id))
  |> sql.bind(sql.Int(author_id))
  |> sql.bind(sql.Text(body))
  |> sql.bind(sql.Timestamp(at))
  |> sql.label("posts.insert")
  |> pool.exec(tx, _)
}

fn get(db: pool.Db, id: Int) -> Result(Option(Thread), sql.Error) {
  select_threads("where id = $1")
  |> sql.bind(sql.Int(id))
  |> sql.label("threads.get")
  |> with_posts(db, _)
  |> result.map(fn(threads) { list.first(threads) |> option.from_result })
}

fn recent(
  db: pool.Db,
  offset: Int,
  limit: Int,
) -> Result(List(Thread), sql.Error) {
  select_threads("order by last_activity desc, id desc limit $1 offset $2")
  |> sql.bind(sql.Int(limit))
  |> sql.bind(sql.Int(offset))
  |> sql.label("threads.recent")
  |> with_posts(db, _)
}

/// A thread row, before its posts are attached.
type Row {
  Row(id: Int, title: String, last_activity: Timestamp)
}

fn select_threads(rest: String) -> sql.Statement(Row) {
  sql.query("select id, title, last_activity from threads " <> rest)
  |> sql.returning({
    use id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use last_activity <- decode.field(2, sql.timestamp_decoder())
    decode.success(Row(id:, title:, last_activity:))
  })
}

/// Run the thread query, then load every thread's posts in one more query.
fn with_posts(
  db: pool.Db,
  threads: sql.Statement(Row),
) -> Result(List(Thread), sql.Error) {
  use rows <- result.try(pool.all(db, threads))
  use posts <- result.map(case rows {
    [] -> Ok([])
    _ ->
      sql.query(
        "select thread_id, id, author_id, body, at
         from posts
         where thread_id = any($1)
         order by id",
      )
      |> sql.bind(sql.Array(list.map(rows, fn(row) { sql.Int(row.id) })))
      |> sql.returning({
        use thread_id <- decode.field(0, decode.int)
        use id <- decode.field(1, decode.int)
        use author_id <- decode.field(2, decode.int)
        use body <- decode.field(3, decode.string)
        use at <- decode.field(4, sql.timestamp_decoder())
        decode.success(#(thread_id, Post(id:, author_id:, body:, at:)))
      })
      |> sql.label("posts.for_threads")
      |> pool.all(db, _)
  })
  let by_thread = list.group(posts, fn(pair) { pair.0 })
  list.map(rows, fn(row) {
    let posts: List(Post) =
      dict.get(by_thread, row.id)
      |> result.unwrap([])
      |> list.reverse
      |> list.map(fn(pair) { pair.1 })
    Thread(
      id: row.id,
      title: row.title,
      posts:,
      last_activity: row.last_activity,
    )
  })
}

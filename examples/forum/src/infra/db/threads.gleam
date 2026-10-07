//// The thread repository, answered from Postgres.

import domain/forum/thread.{type Post, type Thread, Post, Thread}
import domain/forum/thread_repository.{
  type Message, type NewPost, type NewThread, type ThreadRepository, AddPost,
  Get, Open, Recent,
}
import domain/repository.{type Unavailable, Unavailable}
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None}
import gleam/otp/actor
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import gloss/sql

/// Start the repository. Each message is answered in a process of its own,
/// so statements run in parallel on the pool's connections.
pub fn start(db: sql.Db) -> Result(ThreadRepository, actor.StartError) {
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
    Open(thread:, reply:) -> respond(open(db, thread), reply)
    AddPost(post:, reply:) -> respond(add_post(db, post), reply)
    Get(id:, reply:) -> respond(get(db, id), reply)
    Recent(offset:, limit:, reply:) -> respond(recent(db, offset, limit), reply)
  }
}

fn open(db: sql.Db, new: NewThread) -> Result(Thread, sql.Error) {
  let created =
    sql.transaction(db, fn(tx) {
      use id <- result.try(
        sql.query(
          "insert into threads (title, last_activity) values ($1, $2)
           returning id",
        )
        |> sql.bind(sql.Text(new.title))
        |> sql.bind(sql.Timestamp(new.at))
        |> sql.returning(decode.at([0], decode.int))
        |> sql.label("threads.open")
        |> sql.one(tx, _),
      )
      use _ <- result.try(insert_post(tx, id, new.author_id, new.body, new.at))
      Ok(id)
    })
  use id <- result.try(transaction_error(created))
  use thread <- result.try(get(db, id))
  option.to_result(thread, sql.NotFound)
}

fn add_post(db: sql.Db, new: NewPost) -> Result(Option(Thread), sql.Error) {
  let added =
    sql.transaction(db, fn(tx) {
      use touched <- result.try(
        sql.query("update threads set last_activity = $2 where id = $1")
        |> sql.bind(sql.Int(new.thread_id))
        |> sql.bind(sql.Timestamp(new.at))
        |> sql.label("threads.touch")
        |> sql.exec(tx, _),
      )
      case touched {
        0 -> Ok(False)
        _ ->
          insert_post(tx, new.thread_id, new.author_id, new.body, new.at)
          |> result.replace(True)
      }
    })
  case transaction_error(added) {
    Ok(True) -> get(db, new.thread_id)
    Ok(False) -> Ok(None)
    Error(error) -> Error(error)
  }
}

fn insert_post(
  tx: sql.Db,
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
  |> sql.exec(tx, _)
}

fn get(db: sql.Db, id: Int) -> Result(Option(Thread), sql.Error) {
  use threads <- result.map(
    select_threads("where id = $1")
    |> sql.bind(sql.Int(id))
    |> sql.label("threads.get")
    |> with_posts(db, _),
  )
  list.first(threads) |> option.from_result
}

fn recent(
  db: sql.Db,
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
  db: sql.Db,
  threads: sql.Statement(Row),
) -> Result(List(Thread), sql.Error) {
  use rows <- result.try(sql.all(db, threads))
  use posts <- result.map(case rows {
    [] -> Ok([])
    _ ->
      sql.query(
        "select thread_id, id, author_id, body, at from posts
         where thread_id = any($1) order by id",
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
      |> sql.all(db, _)
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

fn transaction_error(
  result: Result(a, sql.TransactionError(sql.Error)),
) -> Result(a, sql.Error) {
  case result {
    Ok(value) -> Ok(value)
    Error(sql.RolledBack(error)) | Error(sql.TransactionFailed(error)) ->
      Error(error)
  }
}

fn respond(
  result: Result(a, sql.Error),
  reply: process.Subject(Result(a, Unavailable)),
) -> Nil {
  process.send(
    reply,
    result.map_error(result, fn(error) { Unavailable(sql.describe(error)) }),
  )
}

//// The forum: threads and their replies, kept in memory.

import domain/forum/thread.{type PostError, type Thread, Post, Thread}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/time/timestamp

pub opaque type Forum {
  Forum(subject: Subject(Message))
}

pub type ReplyError {
  ThreadNotFound
  InvalidReply(PostError)
}

/// One page of threads, most recently active first.
pub type Page {
  Page(threads: List(Thread), number: Int, has_next: Bool)
}

type State {
  State(next_thread: Int, next_post: Int, threads: Dict(Int, Thread))
}

type Message {
  Open(title: String, body: String, author_id: Int, reply: Subject(Thread))
  Reply(
    thread_id: Int,
    body: String,
    author_id: Int,
    reply: Subject(Result(Thread, ReplyError)),
  )
  Get(id: Int, reply: Subject(Result(Thread, Nil)))
  All(reply: Subject(List(Thread)))
}

pub fn start() -> Result(Forum, actor.StartError) {
  actor.new(State(next_thread: 1, next_post: 1, threads: dict.new()))
  |> actor.on_message(on_message)
  |> actor.start
  |> result.map(fn(started) { Forum(started.data) })
}

pub fn open_thread(
  forum: Forum,
  author_id: Int,
  title: String,
  body: String,
) -> Result(Thread, PostError) {
  use title <- result.try(thread.title(title))
  use body <- result.try(thread.body(body))
  Ok(process.call(forum.subject, 5000, Open(title, body, author_id, _)))
}

pub fn reply(
  forum: Forum,
  thread_id: Int,
  author_id: Int,
  body: String,
) -> Result(Thread, ReplyError) {
  use body <- result.try(thread.body(body) |> result.map_error(InvalidReply))
  process.call(forum.subject, 5000, Reply(thread_id, body, author_id, _))
}

pub fn get(forum: Forum, id: Int) -> Result(Thread, Nil) {
  process.call(forum.subject, 5000, Get(id, _))
}

/// Page `number` (from 1) of `size` threads.
pub fn page(forum: Forum, number: Int, size: Int) -> Page {
  let number = case number < 1 {
    True -> 1
    False -> number
  }
  let threads =
    process.call(forum.subject, 5000, All)
    |> list.sort(fn(a, b) {
      timestamp.compare(b.last_activity, a.last_activity)
    })
    |> list.drop({ number - 1 } * size)
  Page(
    threads: list.take(threads, size),
    number:,
    has_next: list.length(threads) > size,
  )
}

fn on_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Open(title:, body:, author_id:, reply:) -> {
      let now = timestamp.system_time()
      let post = Post(id: state.next_post, author_id:, body:, at: now)
      let new =
        Thread(id: state.next_thread, title:, posts: [post], last_activity: now)
      process.send(reply, new)
      actor.continue(State(
        next_thread: state.next_thread + 1,
        next_post: state.next_post + 1,
        threads: dict.insert(state.threads, new.id, new),
      ))
    }
    Reply(thread_id:, body:, author_id:, reply:) ->
      case dict.get(state.threads, thread_id) {
        Error(Nil) -> {
          process.send(reply, Error(ThreadNotFound))
          actor.continue(state)
        }
        Ok(found) -> {
          let now = timestamp.system_time()
          let post = Post(id: state.next_post, author_id:, body:, at: now)
          let updated =
            Thread(
              ..found,
              posts: list.append(found.posts, [post]),
              last_activity: now,
            )
          process.send(reply, Ok(updated))
          actor.continue(
            State(
              ..state,
              next_post: state.next_post + 1,
              threads: dict.insert(state.threads, thread_id, updated),
            ),
          )
        }
      }
    Get(id:, reply:) -> {
      process.send(reply, dict.get(state.threads, id))
      actor.continue(state)
    }
    All(reply:) -> {
      process.send(reply, dict.values(state.threads))
      actor.continue(state)
    }
  }
}

//// The forum: threads and their replies.
////
//// The rules live here and in `domain/forum/thread`; storing threads is the
//// `ThreadRepository`'s job.

import domain/forum/thread.{type PostError, type Thread}
import domain/forum/thread_repository.{type ThreadRepository, NewPost, NewThread}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/time/timestamp

pub opaque type Forum {
  Forum(threads: ThreadRepository)
}

pub type ReplyError {
  ThreadNotFound
  InvalidReply(PostError)
}

/// One page of threads, most recently active first.
pub type Page {
  Page(threads: List(Thread), number: Int, has_next: Bool)
}

pub fn new(threads: ThreadRepository) -> Forum {
  Forum(threads:)
}

pub fn open_thread(
  forum: Forum,
  author_id: Int,
  title: String,
  body: String,
) -> Result(Thread, PostError) {
  use title <- result.try(thread.title(title))
  use body <- result.try(thread.body(body))
  let new = NewThread(title:, author_id:, body:, at: timestamp.system_time())
  Ok(thread_repository.open(forum.threads, new))
}

pub fn reply(
  forum: Forum,
  thread_id: Int,
  author_id: Int,
  body: String,
) -> Result(Thread, ReplyError) {
  use body <- result.try(thread.body(body) |> result.map_error(InvalidReply))
  let post = NewPost(thread_id:, author_id:, body:, at: timestamp.system_time())
  thread_repository.add_post(forum.threads, post)
  |> option.to_result(ThreadNotFound)
}

pub fn get(forum: Forum, id: Int) -> Result(Thread, Nil) {
  thread_repository.get(forum.threads, id) |> option.to_result(Nil)
}

/// Page `number` (from 1) of `size` threads.
pub fn page(forum: Forum, number: Int, size: Int) -> Page {
  let number = int.max(number, 1)
  // One more than a page, to learn whether there is a next one.
  let threads =
    thread_repository.recent(forum.threads, { number - 1 } * size, size + 1)
  Page(
    threads: list.take(threads, size),
    number:,
    has_next: list.length(threads) > size,
  )
}

//// The port for storing threads and their posts: the messages a thread
//// repository answers.

import domain/forum/thread.{type Thread}
import domain/repository.{type Reply}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}

pub type ThreadRepository =
  Subject(Message)

/// A thread not stored yet, with the post that opens it.
pub type NewThread {
  NewThread(title: String, author_id: Int, body: String, at: Timestamp)
}

/// A reply not stored yet. Storing it also makes `at` the thread's last
/// activity.
pub type NewPost {
  NewPost(thread_id: Int, author_id: Int, body: String, at: Timestamp)
}

pub type Message {
  Open(thread: NewThread, reply: Reply(Thread))
  /// The thread with the post added, or `None` when there is no such thread.
  AddPost(post: NewPost, reply: Reply(Option(Thread)))
  Get(id: Int, reply: Reply(Option(Thread)))
  /// Up to `limit` threads after skipping `offset`, most recently active
  /// first, newest first among equals.
  Recent(offset: Int, limit: Int, reply: Reply(List(Thread)))
}

pub fn open(threads: ThreadRepository, thread: NewThread) -> Thread {
  repository.call(threads, Open(thread, _))
}

pub fn add_post(threads: ThreadRepository, post: NewPost) -> Option(Thread) {
  repository.call(threads, AddPost(post, _))
}

pub fn get(threads: ThreadRepository, id: Int) -> Option(Thread) {
  repository.call(threads, Get(id, _))
}

pub fn recent(
  threads: ThreadRepository,
  offset: Int,
  limit: Int,
) -> List(Thread) {
  repository.call(threads, Recent(offset, limit, _))
}

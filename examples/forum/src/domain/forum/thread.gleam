//// Threads, their posts, and the rules for writing them. No IO.

import gleam/list
import gleam/string
import gleam/time/timestamp.{type Timestamp}

pub type Post {
  Post(id: Int, author_id: Int, body: String, at: Timestamp)
}

pub type Thread {
  Thread(
    id: Int,
    title: String,
    /// Oldest first; the first post opens the thread.
    posts: List(Post),
    last_activity: Timestamp,
  )
}

pub type PostError {
  TitleMissing
  TitleTooLong
  BodyMissing
  BodyTooLong
}

pub const max_title = 120

pub const max_body = 10_000

pub fn title(text: String) -> Result(String, PostError) {
  let title = string.trim(text)
  case title, string.length(title) > max_title {
    "", _ -> Error(TitleMissing)
    _, True -> Error(TitleTooLong)
    _, False -> Ok(title)
  }
}

pub fn body(text: String) -> Result(String, PostError) {
  let body = string.trim(text)
  case body, string.length(body) > max_body {
    "", _ -> Error(BodyMissing)
    _, True -> Error(BodyTooLong)
    _, False -> Ok(body)
  }
}

/// Whoever opened the thread.
pub fn author_id(thread: Thread) -> Int {
  case thread.posts {
    [first, ..] -> first.author_id
    [] -> 0
  }
}

pub fn replies(thread: Thread) -> Int {
  list.length(thread.posts) - 1
}

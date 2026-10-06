//// A request body that is read when a handler asks for it.
////
//// A body from the network reads its socket at most once. Its status lives
//// in the connection process's dictionary, so the connection knows after
//// the handler whether the body was consumed (and the connection can be
//// reused) and so a second buffered read returns the same bytes.

import gleam/bit_array
import gleam/erlang/process.{type Subject}

pub type RequestBody {
  RequestBody(
    /// The whole body, up to the server's `max_body`.
    read: fn() -> Result(BitArray, BodyError),
    /// Each piece of the body in turn. The callback returns `False` to stop
    /// early. `Ok` with the total byte count once the body is done.
    stream: fn(fn(BitArray) -> Bool) -> Result(Int, BodyError),
    /// The server's `max_body`, for readers that buffer while streaming.
    limit: Int,
  )
}

/// The server's default `max_body`, used for bodies built in tests.
pub const default_limit = 1_048_576

pub type BodyError {
  /// Larger than `limit` bytes.
  TooLarge(limit: Int)
  /// Badly framed, e.g. a malformed chunk.
  Malformed(reason: String)
  /// The client stopped sending or went away.
  Incomplete
  /// Already streamed, so the bytes are gone.
  Consumed
  /// The stream callback asked to stop.
  Stopped
  /// A `content-encoding` other than gzip.
  UnsupportedEncoding(coding: String)
}

/// A body that is already in memory: for tests, and empty bodies.
pub fn from_bits(bits: BitArray) -> RequestBody {
  RequestBody(
    read: fn() { Ok(bits) },
    stream: fn(consume) {
      case bit_array.byte_size(bits) {
        0 -> Ok(0)
        size ->
          case consume(bits) {
            True -> Ok(size)
            False -> Error(Stopped)
          }
      }
    },
    limit: default_limit,
  )
}

/// How a network body was used. Kept in the process dictionary.
pub type Status {
  Unread
  Buffered(BitArray)
  Streamed
  /// Partly read and abandoned: the connection can't be reused.
  Broken
}

const key = "gloss_http_body"

const watcher_key = "gloss_http_body_watcher"

/// Tell `watcher` each time some of the body arrives, so a deadline on the
/// request can count progress.
pub fn watch(watcher: Subject(Nil)) -> Nil {
  put(watcher_key, watcher)
  Nil
}

/// Report that some of the body arrived.
pub fn progress() -> Nil {
  case get_watcher(watcher_key) {
    Ok(watcher) -> process.send(watcher, Nil)
    Error(Nil) -> Nil
  }
}

@external(erlang, "gloss@http@server_ffi", "pdict_get")
fn get_watcher(key: String) -> Result(Subject(Nil), Nil)

pub fn status() -> Status {
  case get(key) {
    Ok(status) -> status
    Error(Nil) -> Unread
  }
}

pub fn set_status(status: Status) -> Nil {
  put(key, status)
  Nil
}

pub fn reset() -> Nil {
  erase(key)
  Nil
}

@external(erlang, "gloss@http@server_ffi", "pdict_get")
fn get(key: String) -> Result(Status, Nil)

@external(erlang, "erlang", "put")
fn put(key: String, value: anything) -> a

@external(erlang, "erlang", "erase")
fn erase(key: String) -> a

//// Small runtime helpers shared by gloss's packages.

import gleam/erlang/process.{type Subject}

/// Send without crashing when the receiver is gone or its name isn't
/// registered: `False` then. For handlers that must never panic.
@external(erlang, "gloss@internal@runtime_ffi", "try_send")
pub fn try_send(subject: Subject(message), message: message) -> Bool

/// A monotonic clock in nanoseconds, for measuring durations.
@external(erlang, "gloss@internal@runtime_ffi", "monotonic_ns")
pub fn monotonic_ns() -> Int

/// A monotonic clock in milliseconds, for deadlines.
@external(erlang, "gloss@internal@runtime_ffi", "monotonic_ms")
pub fn monotonic_ms() -> Int

/// PBKDF2 with HMAC-SHA256: `length` bytes derived from `password`.
@external(erlang, "gloss@internal@runtime_ffi", "pbkdf2_sha256")
pub fn pbkdf2_sha256(
  password: BitArray,
  salt: BitArray,
  iterations: Int,
  length: Int,
) -> BitArray

/// Bytes as lowercase hex.
@external(erlang, "gloss@internal@runtime_ffi", "lower_hex")
pub fn lower_hex(bytes: BitArray) -> String

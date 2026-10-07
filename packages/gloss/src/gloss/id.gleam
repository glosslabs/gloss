//// Making ids, as a value code is given rather than calls itself.
////
//// Code that names new records takes an `Ids` in its builder, so a test
//// can hand it one that counts (see `gloss/testing/ids` in gloss_test):
////
//// ```gleam
//// let ids = id.uuid_v7(clock.system())
//// id.next(ids)
//// // -> "019a3c4e-8f21-7b3d-9c4e-2f1a6b8d0e57"
//// ```

import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/string
import gleam/time/timestamp
import gloss/clock.{type Clock}

pub opaque type Ids {
  Ids(next: fn() -> String)
}

/// Time-ordered UUIDs (RFC 9562 version 7): 48 bits of milliseconds from
/// `clock`, then 74 random bits. They sort by creation time, so they make
/// good database keys, but they reveal when a record was made.
pub fn uuid_v7(clock: Clock) -> Ids {
  Ids(next: fn() {
    let #(seconds, nanoseconds) =
      clock.now(clock) |> timestamp.to_unix_seconds_and_nanoseconds
    let ms = seconds * 1000 + nanoseconds / 1_000_000
    let assert <<a:size(12), b:size(62), _:size(6)>> =
      crypto.strong_random_bytes(10)
    format(<<ms:size(48), 7:size(4), a:size(12), 2:size(2), b:size(62)>>)
  })
}

/// Random UUIDs (RFC 9562 version 4): 122 random bits.
pub fn uuid_v4() -> Ids {
  Ids(next: fn() {
    let assert <<a:size(48), b:size(12), c:size(62), _:size(6)>> =
      crypto.strong_random_bytes(16)
    format(<<a:size(48), 4:size(4), b:size(12), 2:size(2), c:size(62)>>)
  })
}

/// Ids from `next`.
pub fn new(next: fn() -> String) -> Ids {
  Ids(next:)
}

pub fn next(ids: Ids) -> String {
  ids.next()
}

/// 16 bytes as `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
fn format(bytes: BitArray) -> String {
  let assert <<
    a:bytes-size(4),
    b:bytes-size(2),
    c:bytes-size(2),
    d:bytes-size(2),
    e:bytes-size(6),
  >> = bytes
  [a, b, c, d, e]
  |> list.map(fn(part) { string.lowercase(bit_array.base16_encode(part)) })
  |> string.join("-")
}

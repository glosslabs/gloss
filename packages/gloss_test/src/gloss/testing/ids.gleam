//// Ids for tests that count up, so a test knows the next one in advance.
////
//// ```gleam
//// import gloss/testing/ids as test_ids
////
//// let accounts = accounts.new(users, test_ids.sequential("user_"))
//// let assert Ok(ada) = accounts.register(accounts, "ada@x", "pw")
//// assert ada.id == "user_1"
//// ```
////
//// Each `Ids` counts on its own, from any process.

import gleam/int
import gleam/string
import gloss/id.{type Ids}

type Counter

/// `prefix` followed by 1, 2, 3, ...
pub fn sequential(prefix: String) -> Ids {
  let count = counter_new(0)
  id.new(fn() { prefix <> int.to_string(counter_add(count, 1)) })
}

/// Version 7 UUIDs that count up from
/// `00000000-0000-7000-8000-000000000001`, for code that checks an id's
/// shape.
pub fn uuids() -> Ids {
  let count = counter_new(0)
  id.new(fn() {
    let n = counter_add(count, 1) |> int.to_base16 |> string.lowercase
    "00000000-0000-7000-8000-" <> string.pad_start(n, 12, "0")
  })
}

@external(erlang, "gloss@testing@counter_ffi", "new")
fn counter_new(value: Int) -> Counter

@external(erlang, "gloss@testing@counter_ffi", "add")
fn counter_add(counter: Counter, n: Int) -> Int

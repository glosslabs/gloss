//// A clock for tests that stands still until the test moves it.
////
//// ```gleam
//// import gloss/testing/clock as test_clock
////
//// let time = test_clock.new(timestamp.from_unix_seconds(1_700_000_000))
//// let forum = forum.new(threads, test_clock.clock(time))
//// // ... post a reply ...
//// test_clock.advance(time, duration.minutes(5))
//// ```
////
//// Every `Clock` taken from it reads the same time, from any process, so a
//// test can move the clock of an application it is serving.

import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import gloss/clock.{type Clock}

type Counter

pub opaque type TestClock {
  TestClock(nanoseconds: Counter)
}

/// A clock reading `at`.
pub fn new(at: Timestamp) -> TestClock {
  TestClock(nanoseconds: counter_new(to_nanoseconds(at)))
}

/// The `Clock` to give the code under test.
pub fn clock(time: TestClock) -> Clock {
  clock.new(fn() { now(time) })
}

pub fn now(time: TestClock) -> Timestamp {
  let nanoseconds = counter_get(time.nanoseconds)
  timestamp.from_unix_seconds_and_nanoseconds(0, nanoseconds)
}

/// Move the clock on by `by` (or back, for a negative duration).
pub fn advance(time: TestClock, by: Duration) -> Nil {
  let #(seconds, nanoseconds) = duration.to_seconds_and_nanoseconds(by)
  let _ = counter_add(time.nanoseconds, seconds * 1_000_000_000 + nanoseconds)
  Nil
}

pub fn set(time: TestClock, to: Timestamp) -> Nil {
  counter_put(time.nanoseconds, to_nanoseconds(to))
}

fn to_nanoseconds(at: Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(at)
  seconds * 1_000_000_000 + nanoseconds
}

@external(erlang, "gloss@testing@counter_ffi", "new")
fn counter_new(value: Int) -> Counter

@external(erlang, "gloss@testing@counter_ffi", "get")
fn counter_get(counter: Counter) -> Int

@external(erlang, "gloss@testing@counter_ffi", "put")
fn counter_put(counter: Counter, value: Int) -> Nil

@external(erlang, "gloss@testing@counter_ffi", "add")
fn counter_add(counter: Counter, n: Int) -> Int

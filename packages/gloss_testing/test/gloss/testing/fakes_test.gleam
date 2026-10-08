import gleam/erlang/process
import gleam/time/duration
import gleam/time/timestamp
import gloss/clock
import gloss/id
import gloss/testing/clock as test_clock
import gloss/testing/ids as test_ids

pub fn test_clock_stands_still_until_moved_test() {
  let start = timestamp.from_unix_seconds(1_700_000_000)
  let time = test_clock.new(start)
  let c = test_clock.clock(time)
  assert clock.now(c) == start
  assert clock.now(c) == start

  test_clock.advance(time, duration.milliseconds(1500))
  assert clock.now(c)
    == timestamp.from_unix_seconds_and_nanoseconds(1_700_000_001, 500_000_000)

  test_clock.set(time, timestamp.from_unix_seconds(5))
  assert test_clock.now(time) == timestamp.from_unix_seconds(5)
}

pub fn test_clock_is_shared_across_processes_test() {
  let time = test_clock.new(timestamp.from_unix_seconds(0))
  let c = test_clock.clock(time)
  let read = process.new_subject()
  test_clock.advance(time, duration.seconds(60))
  process.spawn(fn() { process.send(read, clock.now(c)) })
  assert process.receive(read, 1000) == Ok(timestamp.from_unix_seconds(60))
}

pub fn sequential_ids_test() {
  let ids = test_ids.sequential("user_")
  assert id.next(ids) == "user_1"
  assert id.next(ids) == "user_2"
  // Each Ids counts on its own.
  assert id.next(test_ids.sequential("post_")) == "post_1"
}

pub fn uuid_shaped_ids_test() {
  let ids = test_ids.uuids()
  assert id.next(ids) == "00000000-0000-7000-8000-000000000001"
  assert id.next(ids) == "00000000-0000-7000-8000-000000000002"
}

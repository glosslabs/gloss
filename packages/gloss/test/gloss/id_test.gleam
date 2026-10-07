import gleam/list
import gleam/order
import gleam/set
import gleam/string
import gleam/time/timestamp
import gleeunit/should
import gloss/clock
import gloss/id

fn shape(uuid: String, version: String) -> Nil {
  string.length(uuid) |> should.equal(36)
  let assert [a, b, c, d, e] = string.split(uuid, "-")
  #(string.length(a), string.length(b), string.length(d), string.length(e))
  |> should.equal(#(8, 4, 4, 12))
  string.slice(c, 0, 1) |> should.equal(version)
  // The RFC 9562 variant: the top two bits of `d` are 10.
  let assert True = string.contains("89ab", string.slice(d, 0, 1))
  uuid |> should.equal(string.lowercase(uuid))
}

pub fn uuid_v7_carries_the_clock_time_test() {
  // 2023-11-14T22:13:20Z is 0x018bcfe56800 milliseconds.
  let ids = id.uuid_v7(clock.fixed(timestamp.from_unix_seconds(1_700_000_000)))
  let uuid = id.next(ids)
  shape(uuid, "7")
  string.replace(uuid, "-", "")
  |> string.slice(0, 12)
  |> should.equal("018bcfe56800")
  // Random below the time, so two in one millisecond still differ.
  id.next(ids) |> should.not_equal(uuid)
}

pub fn uuid_v7_sorts_by_time_test() {
  let at = fn(seconds) {
    id.next(id.uuid_v7(clock.fixed(timestamp.from_unix_seconds(seconds))))
  }
  string.compare(at(1), at(2)) |> should.equal(order.Lt)
}

pub fn uuid_v4_is_random_test() {
  let ids = id.uuid_v4()
  let uuids = list.repeat(Nil, 100) |> list.map(fn(_) { id.next(ids) })
  list.each(uuids, shape(_, "4"))
  set.size(set.from_list(uuids)) |> should.equal(100)
}

pub fn custom_ids_test() {
  id.next(id.new(fn() { "abc" })) |> should.equal("abc")
}

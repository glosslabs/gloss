import gleam/order
import gleam/time/timestamp
import gleeunit/should
import gloss/clock

pub fn system_clock_reads_the_time_test() {
  let before = timestamp.system_time()
  let now = clock.now(clock.system())
  timestamp.compare(before, now) |> should.not_equal(order.Gt)
}

pub fn fixed_and_custom_clocks_test() {
  let at = timestamp.from_unix_seconds(1_700_000_000)
  clock.now(clock.fixed(at)) |> should.equal(at)
  clock.now(clock.new(fn() { at })) |> should.equal(at)
}

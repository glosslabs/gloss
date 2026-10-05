import gleam/erlang/process
import gleam/option.{None}
import gleam/order
import gleam/time/duration
import gleeunit/should
import gloss/meta
import gloss/tracer
import support.{drain, utc}

fn sample() -> tracer.Event {
  tracer.Point(
    source: "test",
    name: "thing.happened",
    at: utc(2026, 10, 6, 12, 0),
    meta: [],
    level: tracer.Info,
  )
}

pub fn new_is_disabled_and_handle_enables_test() {
  tracer.enabled(tracer.new()) |> should.be_false
  tracer.new()
  |> tracer.handle(fn(_) { Nil })
  |> tracer.enabled
  |> should.be_true
}

pub fn emit_does_not_build_event_when_disabled_test() {
  tracer.emit(tracer.new(), fn() { panic as "event built" })
  |> should.equal(Nil)
}

pub fn point_stamps_now_and_carries_meta_test() {
  let seen = process.new_subject()
  let t = tracer.new() |> tracer.handle(process.send(seen, _))
  tracer.point(t, "test", "thing.happened", tracer.Info, fn() {
    [#("k", meta.Int(1))]
  })
  let assert [
    tracer.Point(
      source: "test",
      name: "thing.happened",
      meta: [#("k", meta.Int(1))],
      level: tracer.Info,
      ..,
    ),
  ] = drain(seen)
}

pub fn span_runs_work_and_skips_meta_when_disabled_test() {
  tracer.span(tracer.new(), "test", "work", fn() { panic as "meta built" }, fn() {
    42
  })
  |> should.equal(42)
}

pub fn span_times_work_and_returns_result_when_enabled_test() {
  let seen = process.new_subject()
  let t = tracer.new() |> tracer.handle(process.send(seen, _))
  tracer.span(t, "test", "work", fn() { [#("k", meta.Bool(True))] }, fn() {
    process.sleep(10)
    "done"
  })
  |> should.equal("done")
  let assert [
    tracer.Span(
      source: "test",
      name: "work",
      meta: [#("k", meta.Bool(True))],
      duration:,
      error: None,
      ..,
    ),
  ] = drain(seen)
  duration.compare(duration, duration.milliseconds(10))
  |> should.not_equal(order.Lt)
}

pub fn handlers_run_in_order_and_are_immutable_test() {
  let seen = process.new_subject()
  let base =
    tracer.new()
    |> tracer.handle(fn(e) { process.send(seen, #("a", e.name)) })
  let more = base |> tracer.handle(fn(e) { process.send(seen, #("b", e.name)) })

  tracer.emit(more, sample)
  drain(seen)
  |> should.equal([#("a", "thing.happened"), #("b", "thing.happened")])

  tracer.emit(base, sample)
  drain(seen) |> should.equal([#("a", "thing.happened")])
}

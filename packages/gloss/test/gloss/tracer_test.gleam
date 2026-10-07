import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/order
import gleam/string
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
    trace: None,
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
      trace:,
      parent_span_id: None,
      ..,
    ),
  ] = drain(seen)
  duration.compare(duration, duration.milliseconds(10))
  |> should.not_equal(order.Lt)
  string.length(trace.trace_id) |> should.equal(32)
  string.length(trace.span_id) |> should.equal(16)
}

pub fn root_and_child_test() {
  let root = tracer.root()
  let child = tracer.child(root)
  child.trace_id |> should.equal(root.trace_id)
  child.span_id |> should.not_equal(root.span_id)
  tracer.root().trace_id |> should.not_equal(root.trace_id)
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

pub fn spans_nest_under_the_current_span_test() {
  let seen = process.new_subject()
  let t = tracer.new() |> tracer.handle(process.send(seen, _))
  assert tracer.current() == None
  let outer = tracer.root()
  tracer.with_current(outer, fn() {
    use <- tracer.span(t, "test", "parent", fn() { [] })
    // Inside a span, it is the current one.
    let assert Some(inner) = tracer.current()
    assert inner.trace_id == outer.trace_id
    tracer.point(t, "test", "noted", tracer.Info, fn() { [] })
  })
  // The previous current span is restored.
  assert tracer.current() == None

  let assert [
    tracer.Point(name: "noted", trace: Some(point_trace), ..),
    tracer.Span(name: "parent", trace:, parent_span_id: Some(parent), ..),
  ] = drain(seen)
  assert parent == outer.span_id
  assert trace.trace_id == outer.trace_id
  assert point_trace == trace
}

pub fn the_current_span_is_restored_after_a_panic_test() {
  let outer = tracer.root()
  let _ = rescue(fn() { tracer.with_current(outer, fn() { panic as "boom" }) })
  assert tracer.current() == None
}

@external(erlang, "gloss@http@server_ffi", "rescue")
fn rescue(work: fn() -> a) -> Result(a, String)

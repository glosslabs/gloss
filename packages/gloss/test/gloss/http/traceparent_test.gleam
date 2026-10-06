import gleeunit/should
import gloss/http/traceparent.{TraceParent}

const trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"

const span_id = "00f067aa0ba902b7"

pub fn parse_test() {
  traceparent.parse("00-" <> trace_id <> "-" <> span_id <> "-01")
  |> should.equal(Ok(TraceParent(trace_id:, span_id:, sampled: True)))
  traceparent.parse("00-" <> trace_id <> "-" <> span_id <> "-00")
  |> should.equal(Ok(TraceParent(trace_id:, span_id:, sampled: False)))
}

pub fn future_versions_are_accepted_test() {
  traceparent.parse("cc-" <> trace_id <> "-" <> span_id <> "-01-extra")
  |> should.equal(Ok(TraceParent(trace_id:, span_id:, sampled: True)))
}

pub fn invalid_values_are_rejected_test() {
  [
    "",
    "00-" <> trace_id <> "-" <> span_id,
    "00-" <> trace_id <> "-" <> span_id <> "-01-extra",
    "ff-" <> trace_id <> "-" <> span_id <> "-01",
    "00-00000000000000000000000000000000-" <> span_id <> "-01",
    "00-" <> trace_id <> "-0000000000000000-01",
    "00-4BF92F3577B34DA6A3CE929D0E0E4736-" <> span_id <> "-01",
    "00-" <> trace_id <> "-" <> span_id <> "-1",
  ]
  |> each(fn(header) { traceparent.parse(header) |> should.equal(Error(Nil)) })
}

pub fn header_round_trips_test() {
  let trace = traceparent.new()
  traceparent.parse(traceparent.header(trace)) |> should.equal(Ok(trace))
}

pub fn child_keeps_the_trace_test() {
  let parent = traceparent.new()
  let child = traceparent.child(parent)
  child.trace_id |> should.equal(parent.trace_id)
  child.span_id |> should.not_equal(parent.span_id)
}

fn each(items: List(a), f: fn(a) -> b) -> Nil {
  case items {
    [] -> Nil
    [x, ..rest] -> {
      f(x)
      each(rest, f)
    }
  }
}

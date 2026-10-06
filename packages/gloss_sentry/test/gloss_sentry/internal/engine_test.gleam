import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import gleeunit/should
import gloss/meta
import gloss/tracer
import gloss_sentry/internal/engine.{type State, Post, Posted, Traced}
import gloss_sentry/internal/envelope
import support.{at, payload, strings_at, test_dsn, utc}

fn now() -> Timestamp {
  utc(2026, 10, 6, 12, 0)
}

fn settings(max_queue: Int, breadcrumbs: Int) -> engine.Settings {
  engine.Settings(
    dsn: test_dsn(),
    environment: "test",
    release: "",
    server_name: "box",
    max_queue:,
    breadcrumbs:,
    trace_id: "0123456789abcdef0123456789abcdef",
  )
}

fn fresh() -> State {
  engine.init(settings(100, 50))
}

fn id() -> String {
  "0123456789abcdef0123456789abcdef"
}

fn span_error(error: String) -> tracer.Event {
  tracer.Span(
    source: "gloss.scheduler",
    name: "task.failed",
    at: now(),
    meta: [#("task", meta.String("t"))],
    duration: duration.seconds(2),
    error: Some(error),
    trace: trace(),
    parent_span_id: None,
  )
}

fn span_ok() -> tracer.Event {
  tracer.Span(
    source: "gloss.scheduler",
    name: "task.succeeded",
    at: now(),
    meta: [#("task", meta.String("t"))],
    duration: duration.seconds(1),
    error: None,
    trace: trace(),
    parent_span_id: None,
  )
}

fn point(level: tracer.Level, name: String) -> tracer.Event {
  tracer.Point(
    source: "gloss.scheduler",
    name:,
    at: now(),
    meta: [],
    level:,
    trace: None,
  )
}

fn feed(state: State, events: List(tracer.Event)) -> State {
  list.fold(events, state, fn(s, e) { engine.handle(s, Traced(e), now(), id).0 })
}

fn values(request) -> List(String) {
  strings_at(payload(request), ["exception", "values"], "value")
}

fn crumbs(request) -> List(String) {
  strings_at(payload(request), ["breadcrumbs", "values"], "message")
}

pub fn failed_span_posts_and_ok_span_does_not_test() {
  let assert #(state, [Post(request)]) =
    engine.handle(fresh(), Traced(span_error("boom")), now(), id)
  state.in_flight |> should.be_true
  state.crumb_count |> should.equal(1)
  values(request) |> should.equal(["boom"])
  at(payload(request), ["timestamp"], decode.string)
  |> should.equal("2026-10-06T12:00:02Z")
  at(payload(request), ["tags", "duration_ms"], decode.string)
  |> should.equal("2000")
  at(payload(request), ["contexts", "trace", "trace_id"], decode.string)
  |> should.equal("4bf92f3577b34da6a3ce929d0e0e4736")
  at(payload(request), ["contexts", "trace", "span_id"], decode.string)
  |> should.equal("00f067aa0ba902b7")

  let #(state, effects) = engine.handle(fresh(), Traced(span_ok()), now(), id)
  effects |> should.equal([])
  state.in_flight |> should.be_false
  state.crumb_count |> should.equal(1)
}

pub fn points_test() {
  let assert #(_, [Post(error)]) =
    engine.handle(fresh(), Traced(point(tracer.Error, "bad")), now(), id)
  at(payload(error), ["level"], decode.string) |> should.equal("error")
  at(payload(error), ["logentry", "formatted"], decode.string)
  |> should.equal("bad")
  let assert #(_, [Post(warning)]) =
    engine.handle(fresh(), Traced(point(tracer.Warning, "meh")), now(), id)
  at(payload(warning), ["level"], decode.string) |> should.equal("warning")
  engine.handle(fresh(), Traced(point(tracer.Info, "fyi")), now(), id).1
  |> should.equal([])
  engine.handle(fresh(), Traced(point(tracer.Debug, "fyi")), now(), id).1
  |> should.equal([])
}

pub fn breadcrumbs_are_attached_oldest_first_test() {
  let state =
    feed(fresh(), [point(tracer.Info, "a"), point(tracer.Info, "b"), span_ok()])
  let assert #(state, [Post(request)]) =
    engine.handle(state, Traced(span_error("boom")), now(), id)
  crumbs(request) |> should.equal(["a", "b", "task.succeeded"])
  // The error is itself a crumb for whatever comes next, which is queued
  // because the first post is still in flight.
  state.crumb_count |> should.equal(4)
  let assert #(state, []) =
    engine.handle(state, Traced(span_error("again")), now(), id)
  let assert [queued] = state.pending
  crumbs(queued)
  |> should.equal(["a", "b", "task.succeeded", "task.failed: boom"])
}

pub fn breadcrumb_ring_is_capped_test() {
  let state =
    engine.init(settings(100, 2))
    |> feed([
      point(tracer.Info, "a"),
      point(tracer.Info, "b"),
      point(tracer.Info, "c"),
    ])
  state.crumb_count |> should.equal(2)
  let assert #(_, [Post(request)]) =
    engine.handle(state, Traced(span_error("boom")), now(), id)
  crumbs(request) |> should.equal(["b", "c"])

  let none = engine.init(settings(100, 0)) |> feed([point(tracer.Info, "a")])
  none.crumb_count |> should.equal(0)
}

pub fn queue_is_capped_drop_oldest_test() {
  let state =
    engine.init(settings(2, 0))
    |> feed([
      span_error("e1"),
      span_error("e2"),
      span_error("e3"),
      span_error("e4"),
      span_error("e5"),
    ])
  state.in_flight |> should.be_true
  state.pending_count |> should.equal(2)
  state.pending |> list.map(values) |> should.equal([["e4"], ["e5"]])
}

pub fn posted_ok_pumps_the_queue_test() {
  let state = fresh() |> feed([span_error("e1"), span_error("e2")])
  let assert #(state, [Post(next)]) =
    engine.handle(state, Posted(Ok(response.new(200))), now(), id)
  values(next) |> should.equal(["e2"])
  state.pending_count |> should.equal(0)
  state.in_flight |> should.be_true
  let assert #(state, []) =
    engine.handle(state, Posted(Ok(response.new(200))), now(), id)
  state.in_flight |> should.be_false
  state.limited_until |> should.equal(None)
}

pub fn rate_limit_drops_until_expiry_test() {
  let state = fresh() |> feed([span_error("e1")])
  let limited = response.new(429) |> response.set_header("retry-after", "60")
  let assert #(state, []) = engine.handle(state, Posted(Ok(limited)), now(), id)
  state.limited_until
  |> should.equal(Some(timestamp.add(now(), duration.seconds(60))))

  let soon = timestamp.add(now(), duration.seconds(1))
  let assert #(state, []) =
    engine.handle(state, Traced(span_error("e2")), soon, id)
  state.pending_count |> should.equal(0)

  let later = timestamp.add(now(), duration.seconds(61))
  let assert #(_, [Post(request)]) =
    engine.handle(state, Traced(span_error("e3")), later, id)
  values(request) |> should.equal(["e3"])
}

pub fn transport_errors_and_5xx_back_off_test() {
  let state = fresh() |> feed([span_error("e1"), span_error("e2")])
  let assert #(state, []) =
    engine.handle(state, Posted(Error("econnrefused")), now(), id)
  state.in_flight |> should.be_false
  state.limited_until
  |> should.equal(Some(timestamp.add(now(), duration.seconds(5))))
  state.pending_count |> should.equal(1)
  // The queued envelope goes once the pause is over and something wakes
  // the engine.
  let later = timestamp.add(now(), duration.seconds(6))
  let assert #(_, [Post(_)]) =
    engine.handle(state, Traced(span_ok()), later, id)

  let state = fresh() |> feed([span_error("e1")])
  let assert #(state, []) =
    engine.handle(state, Posted(Ok(response.new(503))), now(), id)
  state.limited_until
  |> should.equal(Some(timestamp.add(now(), duration.seconds(5))))
}

pub fn poster_down_is_a_failed_post_test() {
  let state = fresh() |> feed([span_error("e1"), span_error("e2")])
  let down =
    process.ProcessDown(
      monitor: process.monitor(process.self()),
      pid: process.self(),
      reason: process.Killed,
    )
  let assert #(state, []) = engine.handle(state, engine.Down(down), now(), id)
  state.in_flight |> should.be_false
  state.limited_until
  |> should.equal(Some(timestamp.add(now(), duration.seconds(5))))
}

pub fn captured_test() {
  let captured =
    engine.Captured(
      at: now(),
      body: envelope.Message("payment declined"),
      meta: [#("order", meta.String("o-1"))],
    )
  let assert #(state, [Post(request)]) =
    engine.handle(fresh(), captured, now(), id)
  at(payload(request), ["logentry", "formatted"], decode.string)
  |> should.equal("payment declined")
  at(payload(request), ["logger"], decode.string)
  |> should.equal("gloss_sentry")
  at(payload(request), ["extra", "order"], decode.string) |> should.equal("o-1")
  state.crumb_count |> should.equal(1)
}

fn trace() -> tracer.SpanContext {
  tracer.SpanContext(
    trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
    span_id: "00f067aa0ba902b7",
  )
}

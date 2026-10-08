import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import gloss/logger
import gloss/meta
import gloss/tracer
import gloss_otel/internal/engine.{Post, Schedule}

fn settings(max_batch: Int, max_queue: Int) -> engine.Settings {
  let assert Ok(traces) =
    engine.signal_request("http://collector:4318/", ["v1", "traces"], [
      #("x-api-key", "k"),
    ])
  let assert Ok(logs) =
    engine.signal_request("http://collector:4318", ["v1", "logs"], [])
  engine.Settings(
    traces:,
    logs:,
    resource: [],
    max_batch:,
    max_queue:,
    interval_ms: 5000,
  )
}

fn at(seconds: Int) -> Timestamp {
  timestamp.from_unix_seconds(seconds)
}

fn span(name: String) -> engine.Message {
  engine.Traced(tracer.Span(
    source: "app",
    name:,
    at: at(0),
    meta: [],
    duration: duration.milliseconds(1),
    error: None,
    trace: tracer.root(),
    parent_span_id: None,
  ))
}

fn run(state: engine.State, messages: List(engine.Message), now: Timestamp) {
  list.fold(messages, #(state, []), fn(acc, message) {
    let #(state, effects) = engine.handle(acc.0, message, now)
    #(state, list.append(acc.1, effects))
  })
}

fn posts(effects: List(engine.Effect)) -> List(request.Request(String)) {
  list.filter_map(effects, fn(effect) {
    case effect {
      Post(req) -> Ok(req)
      _ -> Error(Nil)
    }
  })
}

fn ok() {
  engine.Posted(Ok(response.new(200)))
}

pub fn requests_carry_endpoint_and_headers_test() {
  let s = settings(1, 8)
  assert s.traces.host == "collector"
  assert s.traces.port == Some(4318)
  assert s.traces.path == "/v1/traces"
  assert request.get_header(s.traces, "x-api-key") == Ok("k")
  assert request.get_header(s.traces, "content-type") == Ok("application/json")
  assert engine.signal_request("not a url", ["v1", "logs"], []) == Error(Nil)
}

pub fn a_partial_batch_waits_for_the_tick_test() {
  let #(state, effects) =
    run(engine.init(settings(3, 8)), [span("a"), span("b")], at(0))
  // One tick is scheduled, whatever the number of spans.
  assert effects == [Schedule(5000, engine.Tick)]
  assert !engine.idle(state)

  let #(state, effects) = engine.handle(state, engine.Tick, at(5))
  let assert [req] = posts(effects)
  assert req.path == "/v1/traces"
  assert string.contains(req.body, "\"name\":\"a\"")
  assert string.contains(req.body, "\"name\":\"b\"")

  let #(state, _) = engine.handle(state, ok(), at(5))
  assert engine.idle(state)
}

pub fn a_full_batch_goes_at_once_test() {
  let #(_, effects) =
    run(engine.init(settings(2, 8)), [span("a"), span("b")], at(0))
  assert list.length(posts(effects)) == 1
}

pub fn one_request_is_in_flight_at_a_time_test() {
  let #(state, effects) =
    run(engine.init(settings(1, 8)), [span("a"), span("b")], at(0))
  assert list.length(posts(effects)) == 1
  let #(_, effects) = engine.handle(state, ok(), at(0))
  let assert [req] = posts(effects)
  assert string.contains(req.body, "\"name\":\"b\"")
}

pub fn points_and_entries_are_logs_test() {
  let point =
    engine.Traced(tracer.Point(
      source: "gloss.http",
      name: "server.started",
      at: at(0),
      meta: [],
      level: tracer.Info,
      trace: None,
    ))
  let entry =
    engine.Logged(logger.Entry(
      level: logger.Warning,
      message: "slow",
      meta: [
        #("request_id", meta.String("0af7651916cd43dd8448eb211c80319c")),
        #("ms", meta.Int(900)),
      ],
      at: at(0),
    ))
  let #(state, _) = run(engine.init(settings(10, 8)), [point, entry], at(0))
  let #(_, effects) = engine.handle(state, engine.Tick, at(5))
  let assert [req] = posts(effects)
  assert req.path == "/v1/logs"
  assert string.contains(req.body, "\"eventName\":\"server.started\"")
  assert string.contains(req.body, "\"severityText\":\"WARN\"")
  assert string.contains(
    req.body,
    "\"traceId\":\"0af7651916cd43dd8448eb211c80319c\"",
  )
}

pub fn retryable_failures_back_off_and_retry_test() {
  let #(state, _) = run(engine.init(settings(1, 8)), [span("a")], at(0))
  // A transport error: try again in 1 second, then 2.
  let #(state, effects) =
    engine.handle(state, engine.Posted(Error("econnrefused")), at(0))
  assert effects == [Schedule(1000, engine.Wake)]
  // Nothing is sent while paused, even as new work arrives.
  let #(state, effects) = engine.handle(state, span("b"), at(0))
  assert posts(effects) == []
  let #(state, effects) = engine.handle(state, engine.Wake, at(1))
  let assert [req] = posts(effects)
  assert string.contains(req.body, "\"name\":\"a\"")
  let #(state, effects) =
    engine.handle(state, engine.Posted(Ok(response.new(503))), at(1))
  assert effects == [Schedule(2000, engine.Wake)]

  // Retry-After wins over the backoff.
  let #(state, _) = engine.handle(state, engine.Wake, at(3))
  let busy = response.new(429) |> response.set_header("retry-after", "7")
  let #(state, effects) = engine.handle(state, engine.Posted(Ok(busy)), at(3))
  assert effects == [Schedule(7000, engine.Wake)]

  // Success resets the backoff and sends the rest.
  let #(state, _) = engine.handle(state, engine.Wake, at(10))
  let #(state, effects) = engine.handle(state, ok(), at(10))
  let assert [req] = posts(effects)
  assert string.contains(req.body, "\"name\":\"b\"")
  let #(state, effects) =
    engine.handle(state, engine.Posted(Error("timeout")), at(10))
  assert effects == [Schedule(1000, engine.Wake)]
  assert state.dropped == 0
}

pub fn refused_requests_are_dropped_test() {
  let #(state, _) =
    run(engine.init(settings(1, 8)), [span("a"), span("b")], at(0))
  let #(state, effects) =
    engine.handle(state, engine.Posted(Ok(response.new(400))), at(0))
  assert state.dropped == 1
  let assert [req] = posts(effects)
  assert string.contains(req.body, "\"name\":\"b\"")
}

pub fn a_full_queue_drops_its_oldest_test() {
  // One in flight, two queued; the third queued pushes out the first.
  let #(state, _) =
    run(
      engine.init(settings(1, 2)),
      [span("a"), span("b"), span("c"), span("d")],
      at(0),
    )
  assert state.dropped == 1
  let #(state, effects) = engine.handle(state, ok(), at(0))
  let assert [req] = posts(effects)
  assert string.contains(req.body, "\"name\":\"c\"")
  let #(_, effects) = engine.handle(state, ok(), at(0))
  let assert [req] = posts(effects)
  assert string.contains(req.body, "\"name\":\"d\"")
}

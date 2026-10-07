//// The exporter's state machine, kept pure so batching, queueing and
//// backoff can be tested with fixed timestamps. The process shell in
//// `gloss_otel` feeds it messages and performs its effects.

import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import gloss/logger
import gloss/meta.{type Meta}
import gloss/tracer
import gloss_otel/internal/otlp

pub type Message {
  /// Something the tracer saw.
  Traced(tracer.Event)
  /// An entry written to the log channel.
  Logged(logger.Entry)
  /// The batch interval passed: send what is buffered.
  Tick
  /// A backoff ended: try sending again.
  Wake
  /// The poster finished; `Error` is a transport failure.
  Posted(Result(Response(String), String))
  /// The poster died before reporting.
  Down(process.Down)
  Stop
}

pub type Settings {
  Settings(
    /// Requests for `/v1/traces` and `/v1/logs`, with headers, and no body.
    traces: Request(String),
    logs: Request(String),
    resource: Meta,
    /// Spans or log records per request.
    max_batch: Int,
    /// Requests waiting to be sent; the oldest is dropped beyond this.
    max_queue: Int,
    /// The longest a span or record waits in a partial batch.
    interval_ms: Int,
  )
}

pub type State {
  State(
    settings: Settings,
    /// Newest first.
    spans: List(otlp.Span),
    span_count: Int,
    /// Newest first.
    logs: List(otlp.Log),
    log_count: Int,
    /// Oldest first.
    outbox: List(Request(String)),
    outbox_count: Int,
    in_flight: Option(Request(String)),
    tick_scheduled: Bool,
    paused_until: Option(Timestamp),
    /// Failed attempts in a row, for the backoff.
    failures: Int,
    /// Requests dropped because the queue was full or the collector
    /// refused them.
    dropped: Int,
  )
}

pub type Effect {
  Post(Request(String))
  /// Send `message` back after this many milliseconds.
  Schedule(after_ms: Int, message: Message)
}

pub fn init(settings: Settings) -> State {
  State(
    settings:,
    spans: [],
    span_count: 0,
    logs: [],
    log_count: 0,
    outbox: [],
    outbox_count: 0,
    in_flight: None,
    tick_scheduled: False,
    paused_until: None,
    failures: 0,
    dropped: 0,
  )
}

/// Nothing buffered, queued or in flight.
pub fn idle(state: State) -> Bool {
  state.span_count == 0
  && state.log_count == 0
  && state.outbox_count == 0
  && state.in_flight == None
}

pub fn handle(
  state: State,
  message: Message,
  now: Timestamp,
) -> #(State, List(Effect)) {
  case message {
    Traced(tracer.Span(..) as span) ->
      add_span(state, from_span(span)) |> drive(now)
    Traced(tracer.Point(..) as point) ->
      add_log(state, from_point(point)) |> drive(now)
    Logged(entry) -> add_log(state, from_entry(entry)) |> drive(now)
    Tick ->
      #(State(..state, tick_scheduled: False), [])
      |> seal_spans
      |> seal_logs
      |> drive(now)
    Wake -> #(state, []) |> drive(now)
    Posted(Ok(res)) if res.status >= 200 && res.status < 300 ->
      #(State(..state, in_flight: None, failures: 0), []) |> drive(now)
    Posted(Ok(res)) ->
      case retryable(res.status) {
        True -> retry(state, now, retry_after(res))
        False ->
          #(State(..state, in_flight: None, dropped: state.dropped + 1), [])
          |> drive(now)
      }
    Posted(Error(_)) | Down(_) -> retry(state, now, None)
    Stop -> #(state, [])
  }
}

fn add_span(state: State, span: otlp.Span) -> #(State, List(Effect)) {
  let state =
    State(
      ..state,
      spans: [span, ..state.spans],
      span_count: state.span_count + 1,
    )
  case state.span_count >= state.settings.max_batch {
    True -> seal_spans(#(state, []))
    False -> schedule_tick(state)
  }
}

fn add_log(state: State, log: otlp.Log) -> #(State, List(Effect)) {
  let state =
    State(..state, logs: [log, ..state.logs], log_count: state.log_count + 1)
  case state.log_count >= state.settings.max_batch {
    True -> seal_logs(#(state, []))
    False -> schedule_tick(state)
  }
}

fn schedule_tick(state: State) -> #(State, List(Effect)) {
  case state.tick_scheduled {
    True -> #(state, [])
    False -> #(State(..state, tick_scheduled: True), [
      Schedule(state.settings.interval_ms, Tick),
    ])
  }
}

/// Move the buffered spans into a request at the back of the outbox.
fn seal_spans(step: #(State, List(Effect))) -> #(State, List(Effect)) {
  let #(state, effects) = step
  case state.spans {
    [] -> step
    spans -> {
      let body = otlp.traces(state.settings.resource, list.reverse(spans))
      let state = State(..state, spans: [], span_count: 0)
      #(enqueue(state, request.set_body(state.settings.traces, body)), effects)
    }
  }
}

fn seal_logs(step: #(State, List(Effect))) -> #(State, List(Effect)) {
  let #(state, effects) = step
  case state.logs {
    [] -> step
    logs -> {
      let body = otlp.logs(state.settings.resource, list.reverse(logs))
      let state = State(..state, logs: [], log_count: 0)
      #(enqueue(state, request.set_body(state.settings.logs, body)), effects)
    }
  }
}

fn enqueue(state: State, req: Request(String)) -> State {
  let outbox = list.append(state.outbox, [req])
  case state.outbox_count >= state.settings.max_queue {
    True ->
      State(..state, outbox: list.drop(outbox, 1), dropped: state.dropped + 1)
    False -> State(..state, outbox:, outbox_count: state.outbox_count + 1)
  }
}

/// Post the next request, unless one is in flight or sending is paused.
fn drive(
  step: #(State, List(Effect)),
  now: Timestamp,
) -> #(State, List(Effect)) {
  let #(state, effects) = step
  let paused = case state.paused_until {
    Some(until) -> timestamp.compare(now, until) == order.Lt
    None -> False
  }
  case state.in_flight, state.outbox, paused {
    None, [next, ..rest], False -> #(
      State(
        ..state,
        outbox: rest,
        outbox_count: state.outbox_count - 1,
        in_flight: Some(next),
        paused_until: None,
      ),
      list.append(effects, [Post(next)]),
    )
    _, _, _ -> step
  }
}

/// Put the failed request back at the front and pause: for as long as the
/// collector asked, or else 1, 2, 4 ... up to 30 seconds.
fn retry(
  state: State,
  now: Timestamp,
  after: Option(Int),
) -> #(State, List(Effect)) {
  let failures = state.failures + 1
  let delay_ms = case after {
    Some(seconds) -> seconds * 1000
    None -> int.min(1000 * pow2(failures - 1), 30_000)
  }
  let outbox = case state.in_flight {
    Some(req) -> [req, ..state.outbox]
    None -> state.outbox
  }
  let count = case state.in_flight {
    Some(_) -> state.outbox_count + 1
    None -> state.outbox_count
  }
  #(
    State(
      ..state,
      in_flight: None,
      outbox:,
      outbox_count: count,
      failures:,
      paused_until: Some(timestamp.add(now, duration.milliseconds(delay_ms))),
    ),
    [Schedule(delay_ms, Wake)],
  )
}

fn pow2(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 2 * pow2(n - 1)
  }
}

/// The OTLP/HTTP retryable statuses.
fn retryable(status: Int) -> Bool {
  status == 429 || status == 502 || status == 503 || status == 504
}

/// A `Retry-After` given in seconds.
fn retry_after(res: Response(String)) -> Option(Int) {
  response.get_header(res, "retry-after")
  |> result.try(fn(value) { int.parse(string.trim(value)) })
  |> option.from_result
  |> option.map(int.max(_, 0))
}

// --- From gloss to OTLP -------------------------------------------------------

fn from_span(span: tracer.Event) -> otlp.Span {
  let assert tracer.Span(
    source:,
    name:,
    at:,
    meta:,
    duration:,
    error:,
    trace:,
    parent_span_id:,
  ) = span
  otlp.span(
    source:,
    name:,
    trace_id: trace.trace_id,
    span_id: trace.span_id,
    parent_span_id:,
    at:,
    duration:,
    meta:,
    error:,
  )
}

fn from_point(point: tracer.Event) -> otlp.Log {
  let assert tracer.Point(source:, name:, at:, meta:, level:, trace:) = point
  let #(severity, severity_text) = otlp.severity(tracer_level(level))
  otlp.Log(
    scope: source,
    at:,
    severity:,
    severity_text:,
    body: name,
    event_name: Some(name),
    attributes: meta,
    trace_id: option.map(trace, fn(t) { t.trace_id }),
    span_id: option.map(trace, fn(t) { t.span_id }),
  )
}

/// A log entry. Its `trace_id` and `span_id` meta (or a `request_id` that
/// is a trace id, as gloss/http sets it) tie it to a trace.
fn from_entry(entry: logger.Entry) -> otlp.Log {
  let #(severity, severity_text) =
    otlp.severity(logger.level_to_string(entry.level) |> string.lowercase)
  let text = fn(key) {
    case meta.get(entry.meta, key) {
      Ok(meta.String(value)) -> Ok(value)
      _ -> Error(Nil)
    }
  }
  let trace_id =
    text("trace_id")
    |> result.lazy_or(fn() { text("request_id") })
    |> option.from_result
    |> option.then(otlp.hex_id(_, 32))
  let span_id =
    text("span_id") |> option.from_result |> option.then(otlp.hex_id(_, 16))
  otlp.Log(
    scope: "gloss.logger",
    at: entry.at,
    severity:,
    severity_text:,
    body: entry.message,
    event_name: None,
    attributes: list.filter(entry.meta, fn(e) {
      e.0 != "trace_id" && e.0 != "span_id"
    }),
    trace_id:,
    span_id:,
  )
}

fn tracer_level(level: tracer.Level) -> String {
  case level {
    tracer.Debug -> "debug"
    tracer.Info -> "info"
    tracer.Warning -> "warning"
    tracer.Error -> "error"
  }
}

/// The request for a signal at `endpoint`, e.g. `http://localhost:4318`
/// and `/v1/traces`.
pub fn signal_request(
  endpoint: String,
  path: String,
  headers: List(#(String, String)),
) -> Result(Request(String), Nil) {
  let base = case string.ends_with(endpoint, "/") {
    True -> string.drop_end(endpoint, 1)
    False -> endpoint
  }
  use req <- result.map(request.to(base <> path))
  list.fold(headers, req, fn(req, header) {
    request.set_header(req, header.0, header.1)
  })
  |> request.set_method(http.Post)
  |> request.set_header("content-type", "application/json")
}

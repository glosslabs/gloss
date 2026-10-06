//// The sender's state machine, kept pure so queueing, rate limiting and
//// breadcrumbs can be tested with fixed timestamps. The process shell in
//// `gloss_sentry` feeds it messages and performs the `Post` effects.

import gleam/erlang/process
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
import gloss_sentry/internal/dsn.{type Dsn}
import gloss_sentry/internal/envelope.{type Breadcrumb, type Event}
import gloss_sentry/internal/rate_limit

pub type Message {
  /// Something the tracer saw.
  Traced(tracer.Event)
  /// An explicit `capture`.
  Captured(at: Timestamp, body: envelope.Body, meta: Meta)
  /// An entry for Sentry Logs.
  Logged(logger.Entry)
  /// Send the buffered logs now.
  FlushLogs
  /// The poster finished; `Error` is a transport failure.
  Posted(Result(Response(String), String))
  /// The poster died before reporting.
  Down(process.Down)
  Stop
}

pub type Settings {
  Settings(
    dsn: Dsn,
    environment: String,
    release: String,
    server_name: String,
    /// Envelopes waiting to be posted; the oldest is dropped beyond this.
    max_queue: Int,
    /// Recent events kept as breadcrumbs for the next error.
    breadcrumbs: Int,
    /// The trace id for logs written outside a request: 32 hex characters.
    trace_id: String,
  )
}

/// Logs go out in envelopes of at most this many, per Sentry's SDK spec.
pub const log_batch = 100

/// Buffered logs are sent at most this long after the first one arrives.
pub const log_interval_ms = 5000

pub type State {
  State(
    settings: Settings,
    /// Oldest first.
    pending: List(Request(String)),
    pending_count: Int,
    in_flight: Bool,
    /// Newest first.
    crumbs: List(Breadcrumb),
    crumb_count: Int,
    limited_until: Option(Timestamp),
    /// Newest first.
    logs: List(envelope.Log),
    log_count: Int,
  )
}

pub type Effect {
  Post(Request(String))
  /// Send `FlushLogs` back after this many milliseconds.
  ScheduleFlush(after_ms: Int)
}

pub fn init(settings: Settings) -> State {
  State(
    settings:,
    pending: [],
    pending_count: 0,
    in_flight: False,
    crumbs: [],
    crumb_count: 0,
    limited_until: None,
    logs: [],
    log_count: 0,
  )
}

/// `event_id` is passed in so tests can pin ids.
pub fn handle(
  state: State,
  message: Message,
  now: Timestamp,
  event_id: fn() -> String,
) -> #(State, List(Effect)) {
  case message {
    Traced(event) -> {
      // Any event wakes the queue, so envelopes held back by a pause go out
      // once it is over.
      let #(state, effects) = case to_event(state, event, event_id) {
        Some(sentry_event) -> enqueue(state, sentry_event, now)
        None -> pump(state, now)
      }
      #(add_crumb(state, trace_crumb(event)), effects)
    }
    Captured(at:, body:, meta:) -> {
      let event =
        build(
          state,
          event_id(),
          at,
          envelope.Error,
          "gloss_sentry",
          body,
          [],
          meta,
        )
      let #(state, effects) = enqueue(state, event, now)
      let message = case body {
        envelope.Message(formatted:) -> formatted
        envelope.Exception(value:, ..) -> value
      }
      let crumb =
        envelope.Breadcrumb(
          at:,
          category: "gloss_sentry",
          message:,
          level: envelope.Error,
          data: meta,
        )
      #(add_crumb(state, crumb), effects)
    }
    Posted(Ok(response)) -> {
      let limit = case response.status >= 500 {
        True -> Some(rate_limit.backoff_until(now))
        False -> rate_limit.retry_until(response, now)
      }
      State(
        ..state,
        in_flight: False,
        limited_until: option.or(limit, state.limited_until),
      )
      |> pump(now)
    }
    Posted(Error(_)) | Down(_) ->
      State(
        ..state,
        in_flight: False,
        limited_until: Some(rate_limit.backoff_until(now)),
      )
      |> pump(now)
    Logged(entry) -> {
      let state =
        State(
          ..state,
          logs: [to_log(state, entry), ..state.logs],
          log_count: state.log_count + 1,
        )
      case state.log_count {
        n if n >= log_batch -> flush_logs(state, now)
        1 -> #(state, [ScheduleFlush(log_interval_ms)])
        _ -> #(state, [])
      }
    }
    FlushLogs -> flush_logs(state, now)
    Stop -> #(state, [])
  }
}

fn flush_logs(state: State, now: Timestamp) -> #(State, List(Effect)) {
  case state.logs {
    [] -> #(state, [])
    logs -> {
      let settings = state.settings
      let context =
        envelope.LogContext(
          environment: settings.environment,
          release: settings.release,
          server_name: settings.server_name,
        )
      let request =
        envelope.log_envelope(settings.dsn, list.reverse(logs), context, now)
      State(..state, logs: [], log_count: 0) |> enqueue_request(request, now)
    }
  }
}

/// A log joins the entry's trace: its `trace_id` meta, else a 32-character
/// `request_id` (gloss/http uses the trace id as the request id), else the
/// sender's own trace id.
fn to_log(state: State, entry: logger.Entry) -> envelope.Log {
  let trace_id =
    [meta.get(entry.meta, "trace_id"), meta.get(entry.meta, "request_id")]
    |> list.find_map(fn(found) {
      case found {
        Ok(meta.String(id)) ->
          case string.length(id) == 32 {
            True -> Ok(id)
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
    |> result.unwrap(state.settings.trace_id)
  let level = case entry.level {
    logger.Debug -> envelope.Debug
    logger.Info -> envelope.Info
    logger.Warning -> envelope.Warning
    logger.Error -> envelope.Error
  }
  envelope.Log(
    at: entry.at,
    level:,
    body: entry.message,
    trace_id:,
    attributes: entry.meta,
  )
}

fn limited(state: State, now: Timestamp) -> Bool {
  case state.limited_until {
    Some(until) -> timestamp.compare(now, until) == order.Lt
    None -> False
  }
}

fn enqueue(
  state: State,
  event: Event,
  now: Timestamp,
) -> #(State, List(Effect)) {
  enqueue_request(state, envelope.envelope(state.settings.dsn, event, now), now)
}

fn enqueue_request(
  state: State,
  request: Request(String),
  now: Timestamp,
) -> #(State, List(Effect)) {
  case limited(state, now) {
    True -> #(state, [])
    False -> {
      let #(pending, count) = case
        state.pending_count >= state.settings.max_queue
      {
        True -> #(list.drop(state.pending, 1), state.pending_count - 1)
        False -> #(state.pending, state.pending_count)
      }
      State(
        ..state,
        pending: list.append(pending, [request]),
        pending_count: count + 1,
      )
      |> pump(now)
    }
  }
}

fn pump(state: State, now: Timestamp) -> #(State, List(Effect)) {
  case state.in_flight || limited(state, now), state.pending {
    False, [next, ..rest] -> #(
      State(
        ..state,
        pending: rest,
        pending_count: state.pending_count - 1,
        in_flight: True,
      ),
      [Post(next)],
    )
    _, _ -> #(state, [])
  }
}

fn add_crumb(state: State, crumb: Breadcrumb) -> State {
  let keep = state.settings.breadcrumbs
  case keep <= 0 {
    True -> state
    False -> {
      let crumbs = list.take(state.crumbs, keep - 1)
      State(
        ..state,
        crumbs: [crumb, ..crumbs],
        crumb_count: int.min(state.crumb_count + 1, keep),
      )
    }
  }
}

fn build(
  state: State,
  event_id: String,
  at: Timestamp,
  level: envelope.Level,
  logger: String,
  body: envelope.Body,
  tags: List(#(String, String)),
  extra: Meta,
) -> Event {
  let settings = state.settings
  envelope.Event(
    event_id:,
    at:,
    level:,
    logger:,
    body:,
    tags:,
    extra:,
    breadcrumbs: list.reverse(state.crumbs),
    environment: settings.environment,
    release: settings.release,
    server_name: settings.server_name,
  )
}

/// Failed spans and Error or Warning points become Sentry events; nothing
/// else does.
fn to_event(
  state: State,
  event: tracer.Event,
  event_id: fn() -> String,
) -> Option(Event) {
  case event {
    tracer.Span(source:, name:, at:, meta: m, duration:, error: Some(error)) ->
      Some(build(
        state,
        event_id(),
        timestamp.add(at, duration),
        envelope.Error,
        source,
        envelope.Exception(
          type_: source <> "." <> name,
          value: error,
          frames: [],
          mechanism: "gloss.tracer",
          handled: True,
        ),
        [
          #("source", source),
          #("name", name),
          #("duration_ms", int.to_string(duration.to_milliseconds(duration))),
        ],
        m,
      ))
    tracer.Point(source:, name:, at:, meta: m, level: tracer.Error) ->
      Some(build(
        state,
        event_id(),
        at,
        envelope.Error,
        source,
        envelope.Message(name),
        [
          #("source", source),
          #("name", name),
        ],
        m,
      ))
    tracer.Point(source:, name:, at:, meta: m, level: tracer.Warning) ->
      Some(build(
        state,
        event_id(),
        at,
        envelope.Warning,
        source,
        envelope.Message(name),
        [
          #("source", source),
          #("name", name),
        ],
        m,
      ))
    _ -> None
  }
}

/// Every tracer event is a breadcrumb for the errors that follow it.
fn trace_crumb(event: tracer.Event) -> Breadcrumb {
  case event {
    tracer.Span(source:, name:, at:, meta: m, duration:, error:) -> {
      let took = #("duration_ms", meta.Int(duration.to_milliseconds(duration)))
      let #(message, level) = case error {
        None -> #(name, envelope.Info)
        Some(e) -> #(name <> ": " <> e, envelope.Error)
      }
      envelope.Breadcrumb(
        at: timestamp.add(at, duration),
        category: source,
        message:,
        level:,
        data: list.append(m, [took]),
      )
    }
    tracer.Point(source:, name:, at:, meta: m, level:) ->
      envelope.Breadcrumb(
        at:,
        category: source,
        message: name,
        level: point_level(level),
        data: m,
      )
  }
}

fn point_level(level: tracer.Level) -> envelope.Level {
  case level {
    tracer.Debug -> envelope.Debug
    tracer.Info -> envelope.Info
    tracer.Warning -> envelope.Warning
    tracer.Error -> envelope.Error
  }
}

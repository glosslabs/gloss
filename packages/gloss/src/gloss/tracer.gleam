//// Instrumentation shared by every gloss library.
////
//// A library reports what it does as `Event`s: a `Span` for completed work
//// and a `Point` for a moment in time. The application decides where they go
//// by attaching handlers.
////
//// ```gleam
//// let tracer =
////   tracer.new()
////   |> tracer.handle(fn(event) { io.println(string.inspect(event)) })
////   |> tracer.handle(otel_exporter.send)
//// ```
////
//// One `Tracer` is normally built at boot and given to each library's
//// builder, e.g. `scheduler.tracer(scheduler, tracer)`.
////
//// ## Cost when nothing is listening
////
//// Metadata is passed as a thunk and events are only built when at least one
//// handler is attached, so instrumentation inside a library costs a single
//// list check when the application has attached nothing.
////
//// ## Handler contract
////
//// Handlers run inline in the emitting process, in the order they were
//// attached. They must be cheap and must not panic: a slow handler delays the
//// library that emitted the event, and a panicking one takes that library's
//// process down with it. A handler that exports over the network should hand
//// the event to another process or a buffer and return immediately.
////
//// ## Mapping to OpenTelemetry
////
//// A `Span` is a span: `source` is the instrumentation scope, `name` the span
//// name, `at` the start time, `at` plus `duration` the end time, `meta` the
//// attributes, `error` the status (`Some` is status Error with that
//// description), and `trace` and `parent_span_id` its identity in the
//// trace. A `Point` is a log record or span event: `level` is the severity,
//// `meta` the attributes, and `trace` the span it happened in, if any.

import gleam/bit_array
import gleam/crypto
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import gloss/meta.{type Meta}

/// An ordered set of handlers. Build one with `new` and `handle`.
pub opaque type Tracer {
  Tracer(handlers: List(Handler))
}

pub type Handler =
  fn(Event) -> Nil

/// Something a library did or observed. `source`, `name`, `at` and `meta`
/// are shared by both variants and can be read without matching.
pub type Event {
  /// Completed work that began at `at` and took `duration`.
  Span(
    /// The emitting library, e.g. `"gloss.scheduler"`.
    source: String,
    /// What happened, dotted and lower case, e.g. `"task.succeeded"`.
    name: String,
    at: Timestamp,
    meta: Meta,
    duration: Duration,
    /// The failure, when the work failed.
    error: Option(String),
    /// This span's trace and id.
    trace: SpanContext,
    /// The span this one is part of, when it has one.
    parent_span_id: Option(String),
  )
  /// A moment in time.
  Point(
    source: String,
    name: String,
    at: Timestamp,
    meta: Meta,
    level: Level,
    /// The span this happened in, if any.
    trace: Option(SpanContext),
  )
}

/// Where a span sits in a distributed trace, in W3C Trace Context form.
pub type SpanContext {
  SpanContext(
    /// 32 lowercase hex characters, shared by every span in the trace.
    trace_id: String,
    /// 16 lowercase hex characters, unique to the span.
    span_id: String,
  )
}

/// A span starting a new trace.
pub fn root() -> SpanContext {
  SpanContext(trace_id: random_hex(16), span_id: random_hex(8))
}

/// A new span in `parent`'s trace.
pub fn child(parent: SpanContext) -> SpanContext {
  SpanContext(..parent, span_id: random_hex(8))
}

fn random_hex(bytes: Int) -> String {
  crypto.strong_random_bytes(bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}

pub type Level {
  Debug
  Info
  Warning
  Error
}

/// A tracer with no handlers. Emitting to it does nothing.
pub fn new() -> Tracer {
  Tracer(handlers: [])
}

/// Attach a handler. Handlers are called in the order they were attached.
pub fn handle(tracer: Tracer, handler: Handler) -> Tracer {
  Tracer(handlers: list.append(tracer.handlers, [handler]))
}

/// Whether anything is listening. Use it to skip work that only exists to
/// describe an event; `emit`, `point` and `span` already do.
pub fn enabled(tracer: Tracer) -> Bool {
  tracer.handlers != []
}

/// Build the event and deliver it to every handler, inline, in order. The
/// event is not built when no handler is attached.
pub fn emit(tracer: Tracer, event: fn() -> Event) -> Nil {
  case tracer.handlers {
    [] -> Nil
    handlers -> {
      let event = event()
      list.each(handlers, fn(handler) { handler(event) })
    }
  }
}

/// Emit a `Point` stamped with the current time, outside any span.
pub fn point(
  tracer: Tracer,
  source source: String,
  name name: String,
  level level: Level,
  meta meta: fn() -> Meta,
) -> Nil {
  use <- emit(tracer)
  Point(
    source:,
    name:,
    at: timestamp.system_time(),
    meta: meta(),
    level:,
    trace: None,
  )
}

/// Run `work`, emit a `Span` for it, and return its result. `work` always
/// runs; timing and the span are skipped when nothing is listening. Works
/// with `use`:
///
/// ```gleam
/// use <- tracer.span(tracer, "gloss.sql", "query", fn() {
///   [#("sql", meta.String(sql))]
/// })
/// run_query(sql)
/// ```
///
/// The span starts a new trace. `work` is opaque to `span`: the span's
/// `error` is always `None`, and nothing is emitted if `work` panics.
pub fn span(
  tracer: Tracer,
  source source: String,
  name name: String,
  meta meta: fn() -> Meta,
  work work: fn() -> a,
) -> a {
  case enabled(tracer) {
    False -> work()
    True -> {
      let at = timestamp.system_time()
      let started = monotonic_ns()
      let result = work()
      let duration = duration.nanoseconds(monotonic_ns() - started)
      emit(tracer, fn() {
        Span(
          source:,
          name:,
          at:,
          meta: meta(),
          duration:,
          error: None,
          trace: root(),
          parent_span_id: None,
        )
      })
      result
    }
  }
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

fn monotonic_ns() -> Int {
  monotonic_time(atom.create("nanosecond"))
}

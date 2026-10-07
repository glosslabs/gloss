//// Structured logging shared by the application and every gloss library.
////
//// A `Logger` is a destination for `Entry`s. Build one from a channel
//// (`stdout`, `stderr`, `otp`, `memory`, `discard`, `gloss/logger/file`,
//// or `new` with your own writer), shape it with `min_level`, `max_level`,
//// `with_context` and `stack`, then write to it
//// through its own `debug`, `info`, `warning` and `error` functions:
////
//// ```gleam
//// let log =
////   logger.stack([
////     logger.stderr(),
////     logger.otp() |> logger.min_level(logger.Warning),
////   ])
////   |> logger.with_context([#("app", meta.String("billing"))])
//// log.info("transfer completed", [#("transfer", meta.String("t-17"))])
//// ```
////
//// To log everything a `Tracer` sees, attach `trace_handler`:
//// `tracer.new() |> tracer.handle(logger.trace_handler(log))`.
////
//// ## Writer contract
////
//// Writers run inline in the calling process. They must be cheap and must
//// not panic, for the same reasons as tracer handlers.

import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import gloss/meta.{type Meta}
import gloss/tracer

pub type Level {
  Debug
  Info
  Warning
  Error
}

pub type Entry {
  Entry(level: Level, message: String, meta: Meta, at: Timestamp)
}

pub type Writer =
  fn(Entry) -> Nil

/// A destination for entries, carrying the functions that write to it:
/// `log.info("started", [])`. Every field is derived from one writer, so
/// build loggers with `new`, a channel or a combinator rather than with
/// the constructor.
pub type Logger {
  Logger(
    /// Write an entry at `level`, stamped with the current time.
    log: fn(Level, String, Meta) -> Nil,
    debug: fn(String, Meta) -> Nil,
    info: fn(String, Meta) -> Nil,
    warning: fn(String, Meta) -> Nil,
    error: fn(String, Meta) -> Nil,
    /// Deliver an entry as-is, without stamping the time.
    write: Writer,
  )
}

/// A logger whose functions all deliver entries through `write`.
///
/// Closures that wrap another logger capture only its `write`, never the
/// whole record. A `Logger` is copied into every process it reaches (each
/// request's handler process, for one), and copying doesn't preserve
/// sharing: capturing the record makes each layer of `stack`, `min_level`
/// and the like six times bigger to copy than the one it wraps.
pub fn new(write: Writer) -> Logger {
  let log = fn(level, message, meta) {
    write(Entry(level:, message:, meta:, at: timestamp.system_time()))
  }
  Logger(
    log:,
    debug: fn(message, meta) { log(Debug, message, meta) },
    info: fn(message, meta) { log(Info, message, meta) },
    warning: fn(message, meta) { log(Warning, message, meta) },
    error: fn(message, meta) { log(Error, message, meta) },
    write:,
  )
}

/// Write every entry to each logger, in order.
pub fn stack(loggers: List(Logger)) -> Logger {
  let writes = list.map(loggers, fn(logger) { logger.write })
  new(fn(record) {
    use write <- list.each(writes)
    write(record)
  })
}

/// Drop entries below `level`.
pub fn min_level(logger: Logger, level: Level) -> Logger {
  let floor = rank(level)
  let write = logger.write
  new(fn(record) {
    case rank(record.level) >= floor {
      True -> write(record)
      False -> Nil
    }
  })
}

/// Drop entries above `level`. With `min_level`, splits entries between
/// channels:
///
/// ```gleam
/// logger.stack([
///   logger.stdout() |> logger.max_level(logger.Info),
///   logger.stderr() |> logger.min_level(logger.Warning),
/// ])
/// ```
pub fn max_level(logger: Logger, level: Level) -> Logger {
  let ceiling = rank(level)
  let write = logger.write
  new(fn(record) {
    case rank(record.level) <= ceiling {
      True -> write(record)
      False -> Nil
    }
  })
}

/// Prepend `context` to every entry's meta. Context added earlier comes first.
pub fn with_context(logger: Logger, context: Meta) -> Logger {
  let write = logger.write
  new(fn(record) {
    write(Entry(..record, meta: list.append(context, record.meta)))
  })
}

/// One `format`ted line per entry on standard error.
pub fn stderr() -> Logger {
  new(fn(record) { io.println_error(format(record)) })
}

/// One `format`ted line per entry on standard output.
pub fn stdout() -> Logger {
  new(fn(record) { io.println(format(record)) })
}

/// Send every entry to `subject`. For tests.
pub fn memory(subject: Subject(Entry)) -> Logger {
  new(process.send(subject, _))
}

/// Throw entries away.
pub fn discard() -> Logger {
  new(fn(_) { Nil })
}

/// Forward to Erlang's `logger` at the same level, with the meta both
/// inlined into the message (so the default OTP handler shows it) and
/// attached as metadata with atom keys (so formatter templates and other
/// handlers can read it).
///
/// OTP's primary level defaults to `notice`, which drops `Info` and
/// `Debug`; raise it with `logger:set_primary_config(level, info)` or in
/// `sys.config`.
pub fn otp() -> Logger {
  new(fn(record) {
    otp_log(level_atom(record.level), with_meta(record), record.meta)
  })
}

@external(erlang, "gloss@logger_ffi", "log")
fn otp_log(level: Atom, message: String, meta: Meta) -> Nil

fn level_atom(level: Level) -> Atom {
  atom.create(level_to_string(level))
}

/// The `stderr` line: RFC 3339 UTC time, level, message, then `meta.format`
/// of the meta when there is any.
///
/// ```gleam
/// // 2026-10-06T12:00:00Z info transfer completed transfer="t-17" count=3
/// ```
pub fn format(record: Entry) -> String {
  timestamp.to_rfc3339(record.at, calendar.utc_offset)
  <> " "
  <> level_to_string(record.level)
  <> " "
  <> with_meta(record)
}

/// The message followed by the formatted meta, when there is any.
fn with_meta(record: Entry) -> String {
  case record.meta {
    [] -> record.message
    entries -> record.message <> " " <> meta.format(entries)
  }
}

pub fn level_to_string(level: Level) -> String {
  case level {
    Debug -> "debug"
    Info -> "info"
    Warning -> "warning"
    Error -> "error"
  }
}

fn rank(level: Level) -> Int {
  case level {
    Debug -> 0
    Info -> 1
    Warning -> 2
    Error -> 3
  }
}

/// A tracer handler that logs every event as `from_event` describes.
pub fn trace_handler(logger: Logger) -> tracer.Handler {
  let write = logger.write
  fn(event) { write(from_event(event)) }
}

/// The entry for a tracer event. The message is `source` and `name`
/// separated by a space. A `Point` keeps its level, meta and time. A
/// `Span` is stamped at its end, carries `duration_ms` after the event's
/// meta, and is `Info` when it succeeded or `Error` with an `error` entry
/// when it failed. Both end with `trace_id` and `span_id` when they belong
/// to a span, so log lines can be matched to traces.
pub fn from_event(event: tracer.Event) -> Entry {
  let message = event.source <> " " <> event.name

  case event {
    tracer.Point(at:, meta: event_meta, level:, trace:, ..) -> {
      let ids = case trace {
        Some(trace) -> trace_meta(trace)
        None -> []
      }
      Entry(
        level: from_tracer_level(level),
        message:,
        meta: list.append(event_meta, ids),
        at:,
      )
    }
    tracer.Span(at:, meta: event_meta, duration:, error:, trace:, ..) -> {
      let took = #("duration_ms", meta.Int(duration.to_milliseconds(duration)))
      let #(level, extra) = case error {
        None -> #(Info, [took])
        Some(e) -> #(Error, [took, #("error", meta.String(e))])
      }
      Entry(
        level:,
        message:,
        meta: list.flatten([event_meta, extra, trace_meta(trace)]),
        at: timestamp.add(at, duration),
      )
    }
  }
}

fn trace_meta(trace: tracer.SpanContext) -> Meta {
  [
    #("trace_id", meta.String(trace.trace_id)),
    #("span_id", meta.String(trace.span_id)),
  ]
}

fn from_tracer_level(level: tracer.Level) -> Level {
  case level {
    tracer.Debug -> Debug
    tracer.Info -> Info
    tracer.Warning -> Warning
    tracer.Error -> Error
  }
}

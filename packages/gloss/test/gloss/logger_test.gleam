import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import gloss/logger.{type Entry, type Logger, Entry}
import gloss/meta
import gloss/tracer
import support.{drain, utc}

fn capture() -> #(Logger, Subject(Entry)) {
  let seen = process.new_subject()
  #(logger.memory(seen), seen)
}

const task = #("task", meta.String("t"))

pub fn new_stamps_now_test() {
  let seen = process.new_subject()
  let before = timestamp.system_time()
  let log = logger.new(process.send(seen, _))
  log.info("m", [#("k", meta.Int(1))])
  let after = timestamp.system_time()
  let assert [Entry(level: logger.Info, message: "m", meta: m, at:)] =
    drain(seen)
  m |> should.equal([#("k", meta.Int(1))])
  timestamp.compare(at, before) |> should.not_equal(order.Lt)
  timestamp.compare(at, after) |> should.not_equal(order.Gt)
}

pub fn level_functions_test() {
  let #(log, seen) = capture()
  log.debug("d", [])
  log.info("i", [])
  log.warning("w", [])
  log.error("e", [])
  log.log(logger.Debug, "l", [])
  drain(seen)
  |> list.map(fn(r) { #(r.level, r.message) })
  |> should.equal([
    #(logger.Debug, "d"),
    #(logger.Info, "i"),
    #(logger.Warning, "w"),
    #(logger.Error, "e"),
    #(logger.Debug, "l"),
  ])
}

pub fn format_line_test() {
  let at = utc(2026, 10, 6, 12, 0)
  Entry(
    logger.Info,
    "transfer completed",
    [#("transfer", meta.String("t-17")), #("count", meta.Int(3))],
    at,
  )
  |> logger.format
  |> should.equal(
    "2026-10-06T12:00:00Z info transfer completed transfer=\"t-17\" count=3",
  )
  Entry(logger.Error, "boom", [], at)
  |> logger.format
  |> should.equal("2026-10-06T12:00:00Z error boom")
}

pub fn stack_writes_in_order_test() {
  let seen = process.new_subject()
  let a = logger.new(fn(r) { process.send(seen, #("a", r.message)) })
  let b = logger.new(fn(r) { process.send(seen, #("b", r.message)) })
  logger.stack([a, b]).info("x", [])
  drain(seen) |> should.equal([#("a", "x"), #("b", "x")])
  logger.stack([]).info("y", []) |> should.equal(Nil)
}

pub fn min_level_filters_test() {
  let #(log, seen) = capture()
  let warnings = log |> logger.min_level(logger.Warning)
  warnings.debug("d", [])
  warnings.info("i", [])
  warnings.warning("w", [])
  warnings.error("e", [])
  drain(seen) |> list.map(fn(r) { r.message }) |> should.equal(["w", "e"])

  let everything = log |> logger.min_level(logger.Debug)
  everything.debug("d", [])
  drain(seen) |> list.map(fn(r) { r.message }) |> should.equal(["d"])
}

pub fn with_context_prepends_test() {
  let #(log, seen) = capture()
  let a = #("a", meta.Int(1))
  let b = #("b", meta.Int(2))
  let k = #("k", meta.Int(3))
  logger.with_context(log, [a]).info("m", [k])
  let nested = log |> logger.with_context([a]) |> logger.with_context([b])
  nested.info("m", [k])
  drain(seen)
  |> list.map(fn(r) { r.meta })
  |> should.equal([[a, k], [a, b, k]])
}

pub fn discard_test() {
  logger.discard().error("x", []) |> should.equal(Nil)
}

/// Info and Debug sit below OTP's default `notice` level, so this runs the
/// whole FFI path without printing into the test output.
pub fn otp_channel_does_not_crash_test() {
  let log = logger.otp()
  log.info("gloss logger smoke", [
    #("s", meta.String("x")),
    #("i", meta.Int(1)),
    #("f", meta.Float(1.5)),
    #("b", meta.Bool(True)),
  ])
  |> should.equal(Nil)
  log.debug("no meta", []) |> should.equal(Nil)
}

const span_context =
  tracer.SpanContext(
    trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
    span_id: "00f067aa0ba902b7",
  )

const trace_meta = [
  #("trace_id", meta.String("4bf92f3577b34da6a3ce929d0e0e4736")),
  #("span_id", meta.String("00f067aa0ba902b7")),
]

pub fn from_event_point_in_a_span_test() {
  let point =
    tracer.Point(
      source: "gloss.http",
      name: "csrf.rejected",
      at: utc(2026, 10, 6, 12, 0),
      meta: [task],
      level: tracer.Warning,
      trace: Some(span_context),
    )
  logger.from_event(point).meta |> should.equal([task, ..trace_meta])
}

pub fn from_event_point_test() {
  let at = utc(2026, 10, 6, 12, 0)
  let point = fn(level) {
    tracer.Point(
      source: "gloss.scheduler",
      name: "task.skipped",
      at:,
      meta: [task],
      level:,
      trace: None,
    )
  }
  logger.from_event(point(tracer.Warning))
  |> should.equal(Entry(
    logger.Warning,
    "gloss.scheduler task.skipped",
    [task],
    at,
  ))
  [
    #(tracer.Debug, logger.Debug),
    #(tracer.Info, logger.Info),
    #(tracer.Error, logger.Error),
  ]
  |> list.each(fn(pair) {
    logger.from_event(point(pair.0)).level |> should.equal(pair.1)
  })
}

pub fn from_event_span_test() {
  let at = utc(2026, 10, 6, 12, 0)
  let took = duration.seconds(2)
  let span = fn(error) {
    tracer.Span(
      source: "gloss.scheduler",
      name: "task.finished",
      at:,
      meta: [task],
      duration: took,
      error:,
      trace: span_context,
      parent_span_id: None,
    )
  }
  logger.from_event(span(None))
  |> should.equal(Entry(
    logger.Info,
    "gloss.scheduler task.finished",
    [task, #("duration_ms", meta.Int(2000)), ..trace_meta],
    timestamp.add(at, took),
  ))
  logger.from_event(span(Some("boom")))
  |> should.equal(Entry(
    logger.Error,
    "gloss.scheduler task.finished",
    [
      task,
      #("duration_ms", meta.Int(2000)),
      #("error", meta.String("boom")),
      ..trace_meta
    ],
    timestamp.add(at, took),
  ))
}

pub fn trace_handler_writes_events_test() {
  let #(log, seen) = capture()
  let t = tracer.new() |> tracer.handle(logger.trace_handler(log))
  tracer.point(t, "test", "thing.happened", tracer.Info, fn() { [task] })
  let assert [Entry(level: logger.Info, message: "test thing.happened", ..)] =
    drain(seen)
}

pub fn max_level_filters_test() {
  let #(log, seen) = capture()
  let quiet = log |> logger.max_level(logger.Info)
  quiet.debug("d", [])
  quiet.info("i", [])
  quiet.warning("w", [])
  quiet.error("e", [])
  drain(seen) |> list.map(fn(r) { r.message }) |> should.equal(["d", "i"])
}

pub fn split_channels_test() {
  let out = process.new_subject()
  let err = process.new_subject()
  let log =
    logger.stack([
      logger.memory(out) |> logger.max_level(logger.Info),
      logger.memory(err) |> logger.min_level(logger.Warning),
    ])
  log.debug("d", [])
  log.info("i", [])
  log.warning("w", [])
  log.error("e", [])
  drain(out) |> list.map(fn(r) { r.message }) |> should.equal(["d", "i"])
  drain(err) |> list.map(fn(r) { r.message }) |> should.equal(["w", "e"])
}

// A logger is copied into every process it reaches, and copying expands
// shared terms. Layers of combinators must grow its copy linearly, not
// geometrically.
pub fn layered_loggers_stay_cheap_to_copy_test() {
  let channel = fn() {
    logger.stack([
      logger.discard() |> logger.max_level(logger.Info),
      logger.discard() |> logger.min_level(logger.Warning),
    ])
  }
  let log =
    logger.stack([channel(), channel()])
    |> logger.with_context([])
    |> logger.with_context([])
  assert flat_size(log) < 2000
}

@external(erlang, "erts_debug", "flat_size")
fn flat_size(term: a) -> Int

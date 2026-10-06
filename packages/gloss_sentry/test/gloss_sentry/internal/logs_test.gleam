import gleam/dynamic/decode
import gleam/list
import gleam/time/timestamp.{type Timestamp}
import gleeunit/should
import gloss/logger
import gloss/meta
import gloss_sentry/internal/engine.{
  type Effect, type State, FlushLogs, Logged, Post, ScheduleFlush,
}
import support.{at, lines, payload, test_dsn, utc}

fn now() -> Timestamp {
  utc(2026, 10, 6, 12, 0)
}

const sender_trace = "0123456789abcdef0123456789abcdef"

fn fresh() -> State {
  engine.init(engine.Settings(
    dsn: test_dsn(),
    environment: "test",
    release: "1.2.0",
    server_name: "box",
    max_queue: 100,
    breadcrumbs: 0,
    trace_id: sender_trace,
  ))
}

fn entry(level: logger.Level, message: String, m: meta.Meta) -> logger.Entry {
  logger.Entry(level:, message:, meta: m, at: now())
}

fn log(state: State, e: logger.Entry) -> #(State, List(Effect)) {
  engine.handle(state, Logged(e), now(), fn() { "id" })
}

pub fn first_log_schedules_a_flush_test() {
  let #(state, effects) = log(fresh(), entry(logger.Info, "a", []))
  effects |> should.equal([ScheduleFlush(engine.log_interval_ms)])
  let #(_, effects) = log(state, entry(logger.Info, "b", []))
  effects |> should.equal([])
}

pub fn flush_sends_one_log_envelope_test() {
  let #(state, _) = log(fresh(), entry(logger.Info, "first", []))
  let #(state, _) =
    log(
      state,
      entry(logger.Warning, "second", [
        #("request_id", meta.String("ffffffffffffffffffffffffffffffff")),
        #("count", meta.Int(3)),
      ]),
    )
  let assert #(state, [Post(request)]) =
    engine.handle(state, FlushLogs, now(), fn() { "id" })

  let #(_, item, body) = lines(request)
  at(item, ["type"], decode.string) |> should.equal("log")
  at(item, ["item_count"], decode.int) |> should.equal(2)
  at(item, ["content_type"], decode.string)
  |> should.equal("application/vnd.sentry.items.log+json")

  let items = at(body, ["items"], decode.list(decode.dynamic))
  list.length(items) |> should.equal(2)
  at(body, ["items"], decode.list(decode.at(["body"], decode.string)))
  |> should.equal(["first", "second"])
  at(body, ["items"], decode.list(decode.at(["level"], decode.string)))
  |> should.equal(["info", "warn"])
  at(body, ["items"], decode.list(decode.at(["severity_number"], decode.int)))
  |> should.equal([9, 13])
  // A request's id becomes its trace id; other logs use the sender's.
  at(body, ["items"], decode.list(decode.at(["trace_id"], decode.string)))
  |> should.equal([sender_trace, "ffffffffffffffffffffffffffffffff"])

  attribute(body, 1, ["count", "type"], decode.string)
  |> should.equal("integer")
  attribute(body, 1, ["count", "value"], decode.int) |> should.equal(3)
  attribute(body, 1, ["sentry.environment", "value"], decode.string)
  |> should.equal("test")
  attribute(body, 1, ["sentry.release", "value"], decode.string)
  |> should.equal("1.2.0")

  // The buffer is empty again.
  engine.handle(state, FlushLogs, now(), fn() { "id" }).1 |> should.equal([])
}

pub fn a_full_batch_is_sent_without_waiting_test() {
  let entries =
    list.repeat(Nil, engine.log_batch)
    |> list.index_map(fn(_, i) {
      entry(logger.Debug, "m", [#("i", meta.Int(i))])
    })
  let #(_, effects) =
    list.fold(entries, #(fresh(), []), fn(acc, e) {
      let #(state, effects) = log(acc.0, e)
      #(state, list.append(acc.1, effects))
    })
  let posts =
    list.filter_map(effects, fn(effect) {
      case effect {
        Post(request) -> Ok(request)
        _ -> Error(Nil)
      }
    })
  let assert [request] = posts
  at(payload(request), ["items"], decode.list(decode.dynamic))
  |> list.length
  |> should.equal(engine.log_batch)
}

/// Attribute `path` of the log at `index` in an envelope payload.
fn attribute(
  body: String,
  index: Int,
  path: List(String),
  decoder: decode.Decoder(a),
) -> a {
  let assert [item, ..] =
    at(body, ["items"], decode.list(decode.dynamic)) |> list.drop(index)
  let assert Ok(value) =
    decode.run(item, decode.at(["attributes", ..path], decoder))
  value
}

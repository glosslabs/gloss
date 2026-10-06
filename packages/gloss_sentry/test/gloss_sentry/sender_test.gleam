import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import gloss/meta
import gloss/tracer
import gloss_sentry
import support.{at, drain, dsn_text, fake_send, ok_200, payload, strings_at}

fn span_error(error: String) -> tracer.Event {
  tracer.Span(
    source: "gloss.scheduler",
    name: "task.failed",
    at: timestamp.system_time(),
    meta: [#("task", meta.String("t"))],
    duration: duration.seconds(2),
    error: Some(error),
  )
}

fn point(name: String) -> tracer.Event {
  tracer.Point(
    source: "gloss.scheduler",
    name:,
    at: timestamp.system_time(),
    meta: [],
    level: tracer.Info,
  )
}

fn span_ok() -> tracer.Event {
  tracer.Span(
    source: "gloss.scheduler",
    name: "task.succeeded",
    at: timestamp.system_time(),
    meta: [],
    duration: duration.seconds(1),
    error: None,
  )
}

fn values(request) -> List(String) {
  strings_at(payload(request), ["exception", "values"], "value")
}

pub fn posts_errors_only_test() {
  let seen = process.new_subject()
  let assert Ok(sentry) =
    gloss_sentry.start(gloss_sentry.config(dsn_text), fake_send(seen, ok_200))
  let handle = gloss_sentry.handler(sentry)
  handle(span_error("boom"))
  let assert Ok(request) = process.receive(seen, 500)
  request.path |> should.equal("/api/42/envelope/")
  values(request) |> should.equal(["boom"])
  handle(span_ok())
  process.receive(seen, 100) |> should.equal(Error(Nil))
  gloss_sentry.stop(sentry)
}

pub fn breadcrumbs_cross_the_process_test() {
  let seen = process.new_subject()
  let assert Ok(sentry) =
    gloss_sentry.start(gloss_sentry.config(dsn_text), fake_send(seen, ok_200))
  let handle = gloss_sentry.handler(sentry)
  handle(point("a"))
  handle(point("b"))
  handle(span_error("boom"))
  let assert Ok(request) = process.receive(seen, 500)
  strings_at(payload(request), ["breadcrumbs", "values"], "message")
  |> should.equal(["a", "b"])
  gloss_sentry.stop(sentry)
}

pub fn capture_test() {
  let seen = process.new_subject()
  let assert Ok(sentry) =
    gloss_sentry.config(dsn_text)
    |> gloss_sentry.environment("staging")
    |> gloss_sentry.release("1.2.3")
    |> gloss_sentry.server_name("box")
    |> gloss_sentry.start(fake_send(seen, ok_200))
  gloss_sentry.capture(sentry, "payment declined", [
    #("order", meta.String("o-1")),
  ])
  let assert Ok(request) = process.receive(seen, 500)
  at(payload(request), ["logentry", "formatted"], decode.string)
  |> should.equal("payment declined")
  at(payload(request), ["environment"], decode.string)
  |> should.equal("staging")
  at(payload(request), ["release"], decode.string) |> should.equal("1.2.3")
  at(payload(request), ["server_name"], decode.string) |> should.equal("box")
  gloss_sentry.capture_error(sentry, "timeout", [])
  let assert Ok(request) = process.receive(seen, 500)
  strings_at(payload(request), ["exception", "values"], "type")
  |> should.equal(["error"])
  values(request) |> should.equal(["timeout"])
  gloss_sentry.stop(sentry)
}

pub fn rate_limited_stops_sending_test() {
  let seen = process.new_subject()
  let limited = fn() {
    Ok(response.new(429) |> response.set_header("retry-after", "60"))
  }
  let assert Ok(sentry) =
    gloss_sentry.start(gloss_sentry.config(dsn_text), fake_send(seen, limited))
  let handle = gloss_sentry.handler(sentry)
  handle(span_error("e1"))
  let assert Ok(_) = process.receive(seen, 500)
  handle(span_error("e2"))
  handle(span_error("e3"))
  process.sleep(200)
  drain(seen) |> should.equal([])
  gloss_sentry.stop(sentry)
}

pub fn queue_cap_drops_oldest_test() {
  let seen = process.new_subject()
  let slow = fn() {
    process.sleep(300)
    ok_200()
  }
  let assert Ok(sentry) =
    gloss_sentry.config(dsn_text)
    |> gloss_sentry.max_queue(2)
    |> gloss_sentry.start(fake_send(seen, slow))
  let handle = gloss_sentry.handler(sentry)
  list.each(["e1", "e2", "e3", "e4", "e5"], fn(e) { handle(span_error(e)) })
  process.sleep(1500)
  drain(seen) |> list.map(values) |> should.equal([["e1"], ["e4"], ["e5"]])
  gloss_sentry.stop(sentry)
}

pub fn invalid_dsn_test() {
  let seen = process.new_subject()
  let assert Error(gloss_sentry.InvalidDsn(_)) =
    gloss_sentry.start(gloss_sentry.config("bad"), fake_send(seen, ok_200))
}

pub fn unregistered_name_does_not_panic_test() {
  let sentry = gloss_sentry.from_name(process.new_name("nobody"))
  gloss_sentry.handler(sentry)(span_error("boom")) |> should.equal(Nil)
  gloss_sentry.capture(sentry, "x", []) |> should.equal(Nil)
}

pub fn named_sender_test() {
  let seen = process.new_subject()
  let name = process.new_name("sentry_test")
  let early = gloss_sentry.from_name(name)
  let assert Ok(_) =
    gloss_sentry.config(dsn_text)
    |> gloss_sentry.named(name)
    |> gloss_sentry.start(fake_send(seen, ok_200))
  gloss_sentry.handler(early)(span_error("boom"))
  let assert Ok(_) = process.receive(seen, 500)
  gloss_sentry.stop(early)
  process.sleep(50)
  gloss_sentry.handler(early)(span_error("after stop"))
  process.receive(seen, 100) |> should.equal(Error(Nil))
}

pub fn logger_sends_a_full_batch_test() {
  let seen = process.new_subject()
  let assert Ok(sentry) =
    gloss_sentry.config(dsn_text) |> gloss_sentry.start(fake_send(seen, ok_200))
  let log = gloss_sentry.logger(sentry)
  list.repeat(Nil, 100) |> list.each(fn(_) { log.info("hello", []) })
  let assert Ok(request) = process.receive(seen, 1000)
  at(
    payload(request),
    ["items"],
    decode.list(decode.at(["body"], decode.string)),
  )
  |> list.length
  |> should.equal(100)
  gloss_sentry.stop(sentry)
}

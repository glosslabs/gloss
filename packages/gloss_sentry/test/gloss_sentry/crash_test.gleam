import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/list
import gleam/string
import gloss_sentry
import support.{at, dsn_text, fake_send, ok_200, payload, strings_at}

fn start(seen: Subject(Request(String))) {
  let assert Ok(sentry) =
    gloss_sentry.start(gloss_sentry.config(dsn_text), fake_send(seen, ok_200))
  let assert Ok(Nil) = gloss_sentry.report_crashes(sentry)
  sentry
}

fn exception(request: Request(String), key: String) -> String {
  let assert [value] =
    strings_at(payload(request), ["exception", "values"], key)
  value
}

fn frames(request: Request(String), key: String) -> List(String) {
  at(
    payload(request),
    ["exception", "values"],
    decode.list(decode.at(
      ["stacktrace", "frames"],
      decode.list(decode.at([key], decode.string)),
    )),
  )
  |> list.flatten
}

pub fn a_gleam_panic_is_reported_with_its_stack_test() {
  let seen = process.new_subject()
  let sentry = start(seen)
  process.spawn_unlinked(fn() { crash_with_panic() })

  let assert Ok(request) = process.receive(seen, 2000)
  assert exception(request, "type") == "panic"
  assert string.starts_with(
    exception(request, "value"),
    "worker gave up (gloss_sentry/crash_test.crash_with_panic:",
  )
  // Newest call last, by its Gleam module name. (The panicking function was
  // a tail call, so its caller's frame is the last one left.)
  let assert Ok(last) = list.last(frames(request, "module"))
  assert last == "gloss_sentry/crash_test"
  let assert Ok(last) = list.last(frames(request, "function"))
  assert string.contains(last, "a_gleam_panic_is_reported_with_its_stack_test")
  let mechanism =
    at(
      payload(request),
      ["exception", "values"],
      decode.list(decode.at(["mechanism", "handled"], decode.bool)),
    )
  assert mechanism == [False]
  assert string.contains(payload(request), "\"process\"")

  gloss_sentry.stop_reporting_crashes()
  gloss_sentry.stop(sentry)
}

pub fn an_erlang_error_is_reported_test() {
  let seen = process.new_subject()
  let sentry = start(seen)
  erlang_spawn(fn() { divide(1, list.length([])) })

  let assert Ok(request) = process.receive(seen, 2000)
  assert exception(request, "type") == "badarith"

  gloss_sentry.stop_reporting_crashes()
  gloss_sentry.stop(sentry)
}

pub fn traced_crashes_and_stopped_reporting_are_skipped_test() {
  let seen = process.new_subject()
  let sentry = start(seen)
  // A process a gloss library reports itself.
  process.spawn_unlinked(fn() {
    mark_traced()
    crash_with_panic()
  })
  assert process.receive(seen, 300) == Error(Nil)

  gloss_sentry.stop_reporting_crashes()
  process.spawn_unlinked(fn() { crash_with_panic() })
  assert process.receive(seen, 300) == Error(Nil)
  gloss_sentry.stop(sentry)
}

fn crash_with_panic() -> Nil {
  panic as "worker gave up"
}

@external(erlang, "erlang", "spawn")
fn erlang_spawn(f: fn() -> a) -> process.Pid

@external(erlang, "erlang", "div")
fn divide(a: Int, b: Int) -> Int

@external(erlang, "gloss@logger_ffi", "mark_traced")
fn mark_traced() -> Nil

import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import gloss_sentry/internal/rate_limit
import support.{utc}

fn now() {
  utc(2026, 10, 6, 12, 0)
}

fn after(seconds: Int) {
  Some(timestamp.add(now(), duration.seconds(seconds)))
}

fn check(status: Int, headers: List(#(String, String)), expected) {
  let resp =
    list.fold(headers, response.new(status), fn(r, h) {
      response.set_header(r, h.0, h.1)
    })
  rate_limit.retry_until(resp, now()) |> should.equal(expected)
}

pub fn retry_until_test() {
  check(429, [#("retry-after", "30")], after(30))
  check(429, [#("x-sentry-rate-limits", "120:error:org")], after(120))
  check(429, [#("x-sentry-rate-limits", "60::org")], after(60))
  check(
    429,
    [#("x-sentry-rate-limits", "60:transaction:org"), #("retry-after", "7")],
    after(7),
  )
  check(429, [#("x-sentry-rate-limits", "60:transaction:org")], after(60))
  check(429, [], after(60))
  check(200, [#("x-sentry-rate-limits", "10:error:project:reason")], after(10))
  check(
    200,
    [
      #(
        "x-sentry-rate-limits",
        "10:error:project, 25:error;transaction:org, 99:session:org",
      ),
    ],
    after(25),
  )
  check(200, [#("x-sentry-rate-limits", "2.5:error:org")], after(3))
  check(200, [], None)
  check(500, [], None)
}

pub fn backoff_test() {
  rate_limit.backoff_until(now())
  |> should.equal(timestamp.add(now(), duration.seconds(5)))
}

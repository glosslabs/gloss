//// When a Sentry response says to stop sending, and for how long.

import gleam/float
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}

/// The moment sending may resume, if the response imposes a limit.
/// `X-Sentry-Rate-Limits` wins and applies on any status; a bare 429 falls
/// back to `Retry-After`, then to 60 seconds.
pub fn retry_until(
  response: Response(String),
  now: Timestamp,
) -> Option(Timestamp) {
  let from_header =
    response.get_header(response, "x-sentry-rate-limits")
    |> result.map(longest_error_limit)
    |> result.unwrap(None)
  case from_header, response.status {
    Some(seconds), _ -> Some(timestamp.add(now, duration.seconds(seconds)))
    None, 429 -> {
      let seconds =
        response.get_header(response, "retry-after")
        |> result.try(fn(v) { int.parse(string.trim(v)) })
        |> result.unwrap(60)
      Some(timestamp.add(now, duration.seconds(seconds)))
    }
    None, _ -> None
  }
}

/// A short pause after a transport error or a 5xx, so a Sentry outage does
/// not turn into a tight retry loop.
pub fn backoff_until(now: Timestamp) -> Timestamp {
  timestamp.add(now, duration.seconds(5))
}

/// `retry_after:categories:scope:reason, ...` where categories are
/// `;`-separated and empty means all. Only limits that cover `error` count.
fn longest_error_limit(header: String) -> Option(Int) {
  header
  |> string.split(",")
  |> list.filter_map(fn(entry) {
    case string.split(string.trim(entry), ":") {
      [retry_after, categories, ..] ->
        case covers_errors(categories) {
          True -> parse_seconds(retry_after)
          False -> Error(Nil)
        }
      [retry_after] -> parse_seconds(retry_after)
      [] -> Error(Nil)
    }
  })
  |> list.reduce(int.max)
  |> option.from_result
}

fn covers_errors(categories: String) -> Bool {
  case string.split(categories, ";") |> list.filter(fn(c) { c != "" }) {
    [] -> True
    some -> list.contains(some, "error")
  }
}

fn parse_seconds(text: String) -> Result(Int, Nil) {
  let text = string.trim(text)
  case int.parse(text) {
    Ok(n) -> Ok(n)
    Error(Nil) ->
      float.parse(text) |> result.map(fn(f) { float.round(float.ceiling(f)) })
  }
}

import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/option.{None}
import gleam/string
import gleam/time/calendar.{Date, TimeOfDay}
import gleam/time/timestamp.{type Timestamp}
import gloss_sentry/internal/dsn.{type Dsn, type DsnError}
import gloss_sentry/internal/envelope.{type Event}

/// A UTC timestamp from civil fields.
pub fn utc(y: Int, mo: Int, d: Int, h: Int, mi: Int) -> Timestamp {
  let assert Ok(month) = calendar.month_from_int(mo)
  timestamp.from_calendar(
    Date(y, month, d),
    TimeOfDay(h, mi, 0, 0),
    calendar.utc_offset,
  )
}

/// Everything currently queued on a subject, in order, without waiting.
pub fn drain(subject: Subject(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(x) -> [x, ..drain(subject)]
    Error(Nil) -> []
  }
}

pub const dsn_text = "https://abc@o1.ingest.sentry.io/42"

pub fn dsn_parse(text: String) -> Result(Dsn, DsnError) {
  dsn.parse(text)
}

pub fn test_dsn() -> Dsn {
  let assert Ok(parsed) = dsn.parse(dsn_text)
  parsed
}

/// A `send` that records requests on `seen` and answers with `reply`.
pub fn fake_send(
  seen: Subject(Request(String)),
  reply: fn() -> Result(Response(String), String),
) -> fn(Request(String)) -> Result(Response(String), String) {
  fn(request) {
    process.send(seen, request)
    reply()
  }
}

pub fn ok_200() -> Result(Response(String), String) {
  Ok(response.new(200))
}

/// The three lines of an envelope body: header, item header, payload.
pub fn lines(request: Request(String)) -> #(String, String, String) {
  let assert [header, item, payload, ""] = string.split(request.body, "\n")
  #(header, item, payload)
}

pub fn payload(request: Request(String)) -> String {
  lines(request).2
}

/// Decode a value at `path` in a JSON document, or fail the test.
pub fn at(json_text: String, path: List(String), decoder: Decoder(a)) -> a {
  let assert Ok(value) = json.parse(json_text, decode.at(path, decoder))
  value
}

/// The string field `key` of every object in the list at `path`.
pub fn strings_at(
  json_text: String,
  path: List(String),
  key: String,
) -> List(String) {
  at(json_text, path, decode.list(decode.at([key], decode.string)))
}

/// An event with sensible defaults for the fields a test does not care about.
pub fn event(level: envelope.Level, body: envelope.Body) -> Event {
  envelope.Event(
    event_id: "0123456789abcdef0123456789abcdef",
    at: utc(2026, 10, 6, 12, 0),
    level:,
    logger: "gloss.scheduler",
    body:,
    tags: [#("task", "t")],
    extra: [],
    breadcrumbs: [],
    environment: "test",
    release: "",
    server_name: "box",
    trace: None,
  )
}

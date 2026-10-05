import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import gloss/meta
import gloss_sentry/internal/envelope.{Exception, Frame, Message}
import support.{at, event, lines, strings_at, test_dsn, utc}

fn failed() -> envelope.Event {
  envelope.Event(
    ..event(
      envelope.Error,
      Exception(
        type_: "gloss.scheduler.task.failed",
        value: "boom",
        frames: [],
        mechanism: "gloss.tracer",
        handled: True,
      ),
    ),
    tags: [#("task", "t"), #("duration_ms", "2000")],
    extra: [#("task", meta.String("t")), #("attempt", meta.Int(2))],
  )
}

fn sent_at() {
  utc(2026, 10, 6, 12, 5)
}

pub fn request_shape_test() {
  let req = envelope.envelope(test_dsn(), failed(), sent_at())
  req.method |> should.equal(http.Post)
  req.scheme |> should.equal(http.Https)
  req.host |> should.equal("o1.ingest.sentry.io")
  req.path |> should.equal("/api/42/envelope/")
  request.get_header(req, "content-type")
  |> should.equal(Ok("application/x-sentry-envelope"))
  request.get_header(req, "user-agent")
  |> should.equal(Ok("gloss_sentry/0.1.0"))
  request.get_header(req, "x-sentry-auth")
  |> should.equal(Ok(
    "Sentry sentry_version=7, sentry_client=gloss_sentry/0.1.0, sentry_key=abc",
  ))
}

pub fn port_is_set_when_present_test() {
  let assert Ok(parsed) =
    support.dsn_parse("https://abc@sentry.example.com:9000/7")
  let req = envelope.envelope(parsed, failed(), sent_at())
  req.port |> should.equal(Some(9000))
}

pub fn body_lines_test() {
  let req = envelope.envelope(test_dsn(), failed(), sent_at())
  let #(header, item, payload) = lines(req)
  at(header, ["event_id"], decode.string)
  |> should.equal("0123456789abcdef0123456789abcdef")
  at(header, ["sent_at"], decode.string)
  |> should.equal("2026-10-06T12:05:00Z")
  at(header, ["sdk", "name"], decode.string)
  |> should.equal("gloss.gleam.sentry")
  at(item, ["type"], decode.string) |> should.equal("event")
  at(item, ["content_type"], decode.string)
  |> should.equal("application/json")
  at(item, ["length"], decode.int)
  |> should.equal(bit_array.byte_size(bit_array.from_string(payload)))
}

pub fn exception_event_test() {
  let payload =
    support.payload(envelope.envelope(test_dsn(), failed(), sent_at()))
  at(payload, ["level"], decode.string) |> should.equal("error")
  at(payload, ["logger"], decode.string) |> should.equal("gloss.scheduler")
  at(payload, ["platform"], decode.string) |> should.equal("other")
  at(payload, ["timestamp"], decode.string)
  |> should.equal("2026-10-06T12:00:00Z")
  at(payload, ["environment"], decode.string) |> should.equal("test")
  at(payload, ["server_name"], decode.string) |> should.equal("box")
  strings_at(payload, ["exception", "values"], "type")
  |> should.equal(["gloss.scheduler.task.failed"])
  strings_at(payload, ["exception", "values"], "value")
  |> should.equal(["boom"])
  at(
    payload,
    ["exception", "values"],
    decode.list(decode.at(["mechanism", "handled"], decode.bool)),
  )
  |> should.equal([True])
  at(payload, ["tags", "duration_ms"], decode.string) |> should.equal("2000")
  at(payload, ["extra", "task"], decode.string) |> should.equal("t")
  at(payload, ["extra", "attempt"], decode.int) |> should.equal(2)
  string.contains(payload, "\"logentry\"") |> should.be_false
  string.contains(payload, "\"stacktrace\"") |> should.be_false
  string.contains(payload, "\"release\"") |> should.be_false
}

pub fn message_event_and_release_test() {
  let e =
    envelope.Event(
      ..event(envelope.Warning, Message("task.skipped")),
      release: "1.2.3",
    )
  let payload = support.payload(envelope.envelope(test_dsn(), e, sent_at()))
  at(payload, ["logentry", "formatted"], decode.string)
  |> should.equal("task.skipped")
  at(payload, ["level"], decode.string) |> should.equal("warning")
  at(payload, ["release"], decode.string) |> should.equal("1.2.3")
  string.contains(payload, "\"exception\"") |> should.be_false
}

pub fn frames_test() {
  let e =
    event(
      envelope.Error,
      Exception(
        type_: "panic",
        value: "boom",
        frames: [
          Frame("erl_eval", "do_apply/7", "erl_eval.erl", 1042),
          Frame("m", "f", "", 0),
          Frame("app/thing", "run", "src/app/thing.gleam", 12),
        ],
        mechanism: "otp.logger",
        handled: False,
      ),
    )
  let payload = support.payload(envelope.envelope(test_dsn(), e, sent_at()))
  let path = ["exception", "values"]
  let frames = ["stacktrace", "frames"]
  at(
    payload,
    path,
    decode.list(decode.at(
      frames,
      decode.list(decode.at(["function"], decode.string)),
    )),
  )
  |> should.equal([["do_apply/7", "f", "run"]])
  at(
    payload,
    path,
    decode.list(decode.at(
      frames,
      decode.list(decode.at(["in_app"], decode.bool)),
    )),
  )
  |> should.equal([[False, False, True]])
  at(
    payload,
    path,
    decode.list(decode.at(
      frames,
      decode.list(decode.optional_field("lineno", 0, decode.int, decode.success)),
    )),
  )
  |> should.equal([[1042, 0, 12]])
  at(
    payload,
    path,
    decode.list(decode.at(
      frames,
      decode.list(decode.optional_field(
        "filename",
        "-",
        decode.string,
        decode.success,
      )),
    )),
  )
  |> should.equal([["erl_eval.erl", "-", "src/app/thing.gleam"]])
}

pub fn breadcrumbs_test() {
  let crumb = fn(message, level) {
    envelope.Breadcrumb(
      at: utc(2026, 10, 6, 11, 59),
      category: "gloss.scheduler",
      message:,
      level:,
      data: [#("task", meta.String("t"))],
    )
  }
  let e =
    envelope.Event(..failed(), breadcrumbs: [
      crumb("a", envelope.Info),
      crumb("b", envelope.Error),
    ])
  let payload = support.payload(envelope.envelope(test_dsn(), e, sent_at()))
  let values = ["breadcrumbs", "values"]
  strings_at(payload, values, "message") |> should.equal(["a", "b"])
  strings_at(payload, values, "type") |> should.equal(["default", "error"])
  strings_at(payload, values, "level") |> should.equal(["info", "error"])
  strings_at(payload, values, "timestamp")
  |> should.equal(["2026-10-06T11:59:00Z", "2026-10-06T11:59:00Z"])
  at(payload, values, decode.list(decode.at(["data", "task"], decode.string)))
  |> should.equal(["t", "t"])
}

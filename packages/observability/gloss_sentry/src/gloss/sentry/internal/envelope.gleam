//// The Sentry event payload and the envelope that carries it, as pure
//// functions from data to JSON and to an HTTP request.

import gleam/bit_array
import gleam/http.{Post}
import gleam/http/request.{type Request}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import gloss/meta.{type Meta, type Value}
import gloss/sentry/internal/dsn.{type Dsn}

/// `entity.ecosystem.flavor`, per Sentry's SDK interface.
pub const sdk_name = "gloss.gleam.sentry"

pub const sdk_version = "0.1.0"

/// `sentry_client` in the auth header and the `user-agent`.
pub const client = "gloss_sentry/0.1.0"

pub type Level {
  Fatal
  Error
  Warning
  Info
  Debug
}

/// One stack frame. Empty strings and a zero line mean unknown and are
/// left out of the JSON.
pub type Frame {
  Frame(module: String, function: String, filename: String, line: Int)
}

pub type Body {
  /// A log-like event with no exception.
  Message(formatted: String)
  /// An exception. `frames` run oldest to newest; the last one raised.
  Exception(
    type_: String,
    value: String,
    frames: List(Frame),
    mechanism: String,
    handled: Bool,
  )
}

pub type Breadcrumb {
  Breadcrumb(
    at: Timestamp,
    category: String,
    message: String,
    level: Level,
    data: Meta,
  )
}

pub type Event {
  Event(
    /// 32 lowercase hex characters.
    event_id: String,
    at: Timestamp,
    level: Level,
    logger: String,
    body: Body,
    tags: List(#(String, String)),
    extra: Meta,
    /// Oldest first.
    breadcrumbs: List(Breadcrumb),
    environment: String,
    /// Left out of the JSON when empty.
    release: String,
    server_name: String,
    /// The span the event happened in, as `contexts.trace`.
    trace: Option(Trace),
  )
}

pub type Trace {
  Trace(trace_id: String, span_id: String, parent_span_id: Option(String))
}

pub fn rfc3339(at: Timestamp) -> String {
  timestamp.to_rfc3339(at, calendar.utc_offset)
}

pub fn level_string(level: Level) -> String {
  case level {
    Fatal -> "fatal"
    Error -> "error"
    Warning -> "warning"
    Info -> "info"
    Debug -> "debug"
  }
}

pub fn value_json(value: Value) -> Json {
  case value {
    meta.String(s) -> json.string(s)
    meta.Int(i) -> json.int(i)
    meta.Float(f) -> json.float(f)
    meta.Bool(b) -> json.bool(b)
  }
}

fn meta_json(entries: Meta) -> Json {
  json.object(list.map(entries, fn(entry) { #(entry.0, value_json(entry.1)) }))
}

pub fn event_json(event: Event) -> Json {
  let sdk =
    json.object([
      #("name", json.string(sdk_name)),
      #("version", json.string(sdk_version)),
    ])
  let tags =
    list.map(event.tags, fn(tag) {
      #(tag.0, json.string(string.slice(tag.1, 0, 200)))
    })
  json.object(
    list.flatten([
      [
        #("event_id", json.string(event.event_id)),
        #("timestamp", json.string(rfc3339(event.at))),
        #("platform", json.string("other")),
        #("level", json.string(level_string(event.level))),
        #("logger", json.string(event.logger)),
        #("environment", json.string(event.environment)),
        #("server_name", json.string(event.server_name)),
        #("sdk", sdk),
        #("tags", json.object(tags)),
        #("extra", meta_json(event.extra)),
        #(
          "breadcrumbs",
          json.object([
            #("values", json.array(event.breadcrumbs, breadcrumb_json)),
          ]),
        ),
      ],
      case event.release {
        "" -> []
        release -> [#("release", json.string(release))]
      },
      case event.trace {
        Some(trace) -> [
          #("contexts", json.object([#("trace", trace_json(trace))])),
        ]
        None -> []
      },
      body_json(event.body),
    ]),
  )
}

fn trace_json(trace: Trace) -> Json {
  json.object([
    #("trace_id", json.string(trace.trace_id)),
    #("span_id", json.string(trace.span_id)),
    ..case trace.parent_span_id {
      Some(parent) -> [#("parent_span_id", json.string(parent))]
      None -> []
    }
  ])
}

fn body_json(body: Body) -> List(#(String, Json)) {
  case body {
    Message(formatted:) -> [
      #("logentry", json.object([#("formatted", json.string(formatted))])),
    ]
    Exception(type_:, value:, frames:, mechanism:, handled:) -> {
      let stacktrace = case frames {
        [] -> []
        _ -> [
          #(
            "stacktrace",
            json.object([#("frames", json.array(frames, frame_json))]),
          ),
        ]
      }
      let exception =
        json.object(
          list.flatten([
            [
              #("type", json.string(type_)),
              #("value", json.string(value)),
              #(
                "mechanism",
                json.object([
                  #("type", json.string(mechanism)),
                  #("handled", json.bool(handled)),
                ]),
              ),
            ],
            stacktrace,
          ]),
        )
      [
        #(
          "exception",
          json.object([#("values", json.preprocessed_array([exception]))]),
        ),
      ]
    }
  }
}

fn frame_json(frame: Frame) -> Json {
  let when = fn(condition, entry) {
    case condition {
      True -> [entry]
      False -> []
    }
  }
  json.object(
    list.flatten([
      [#("function", json.string(frame.function))],
      when(frame.module != "", #("module", json.string(frame.module))),
      when(frame.filename != "", #("filename", json.string(frame.filename))),
      when(frame.line > 0, #("lineno", json.int(frame.line))),
      [#("in_app", json.bool(string.ends_with(frame.filename, ".gleam")))],
    ]),
  )
}

fn breadcrumb_json(crumb: Breadcrumb) -> Json {
  let type_ = case crumb.level {
    Fatal | Error -> "error"
    _ -> "default"
  }
  json.object([
    #("timestamp", json.string(rfc3339(crumb.at))),
    #("type", json.string(type_)),
    #("category", json.string(crumb.category)),
    #("message", json.string(crumb.message)),
    #("level", json.string(level_string(crumb.level))),
    #("data", meta_json(crumb.data)),
  ])
}

/// The POST for one event: envelope header, item header and payload on
/// three `\n`-terminated lines. `sent_at` is passed in so the output is
/// deterministic.
pub fn envelope(dsn: Dsn, event: Event, sent_at: Timestamp) -> Request(String) {
  let payload = json.to_string(event_json(event))
  let header =
    json.object([
      #("event_id", json.string(event.event_id)),
      #("sent_at", json.string(rfc3339(sent_at))),
      #(
        "sdk",
        json.object([
          #("name", json.string(sdk_name)),
          #("version", json.string(sdk_version)),
        ]),
      ),
    ])
  let item =
    json.object([
      #("type", json.string("event")),
      #("content_type", json.string("application/json")),
      #("length", json.int(bit_array.byte_size(bit_array.from_string(payload)))),
    ])
  let body =
    json.to_string(header)
    <> "\n"
    <> json.to_string(item)
    <> "\n"
    <> payload
    <> "\n"
  post(dsn, body)
}

fn post(dsn: Dsn, body: String) -> Request(String) {
  let auth =
    "Sentry sentry_version=7, sentry_client="
    <> client
    <> ", sentry_key="
    <> dsn.public_key
  let base =
    request.new()
    |> request.set_method(Post)
    |> request.set_scheme(dsn.scheme)
    |> request.set_host(dsn.host)
    |> request.set_path(dsn.envelope_path(dsn))
  let with_port = case dsn.port {
    Some(port) -> request.set_port(base, port)
    None -> base
  }
  with_port
  |> request.set_header("content-type", "application/x-sentry-envelope")
  |> request.set_header("user-agent", client)
  |> request.set_header("x-sentry-auth", auth)
  |> request.set_body(body)
}

// --- Logs --------------------------------------------------------------------

/// One entry for Sentry's Logs product.
pub type Log {
  Log(
    at: Timestamp,
    level: Level,
    body: String,
    /// 32 lowercase hex characters.
    trace_id: String,
    attributes: Meta,
  )
}

/// What every log is tagged with.
pub type LogContext {
  LogContext(environment: String, release: String, server_name: String)
}

pub fn log_json(log: Log, context: LogContext) -> Json {
  let #(level, severity) = case log.level {
    Debug -> #("debug", 5)
    Info -> #("info", 9)
    Warning -> #("warn", 13)
    Error -> #("error", 17)
    Fatal -> #("fatal", 21)
  }
  let defaults =
    list.flatten([
      [
        #("sentry.environment", meta.String(context.environment)),
        #("sentry.sdk.name", meta.String(sdk_name)),
        #("sentry.sdk.version", meta.String(sdk_version)),
        #("server.address", meta.String(context.server_name)),
      ],
      case context.release {
        "" -> []
        release -> [#("sentry.release", meta.String(release))]
      },
    ])
  json.object([
    #("timestamp", json.float(timestamp.to_unix_seconds(log.at))),
    #("trace_id", json.string(log.trace_id)),
    #("level", json.string(level)),
    #("severity_number", json.int(severity)),
    #("body", json.string(log.body)),
    #(
      "attributes",
      json.object(
        list.map(list.append(log.attributes, defaults), fn(entry) {
          #(entry.0, attribute_json(entry.1))
        }),
      ),
    ),
  ])
}

fn attribute_json(value: Value) -> Json {
  let #(type_, json_value) = case value {
    meta.String(s) -> #("string", json.string(s))
    meta.Int(i) -> #("integer", json.int(i))
    meta.Float(f) -> #("double", json.float(f))
    meta.Bool(b) -> #("boolean", json.bool(b))
  }
  json.object([#("value", json_value), #("type", json.string(type_))])
}

/// The POST for a batch of logs, oldest first, as one `log` item.
pub fn log_envelope(
  dsn: Dsn,
  logs: List(Log),
  context: LogContext,
  sent_at: Timestamp,
) -> Request(String) {
  let payload =
    json.to_string(
      json.object([
        #("items", json.array(logs, fn(log) { log_json(log, context) })),
      ]),
    )
  let header =
    json.object([
      #("sent_at", json.string(rfc3339(sent_at))),
      #(
        "sdk",
        json.object([
          #("name", json.string(sdk_name)),
          #("version", json.string(sdk_version)),
        ]),
      ),
    ])
  let item =
    json.object([
      #("type", json.string("log")),
      #("item_count", json.int(list.length(logs))),
      #("content_type", json.string("application/vnd.sentry.items.log+json")),
      #("length", json.int(bit_array.byte_size(bit_array.from_string(payload)))),
    ])
  post(
    dsn,
    json.to_string(header)
      <> "\n"
      <> json.to_string(item)
      <> "\n"
      <> payload
      <> "\n",
  )
}

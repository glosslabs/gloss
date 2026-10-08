//// OTLP/JSON bodies for `/v1/traces` and `/v1/logs`.
////
//// Ids are hex strings and 64-bit integers are decimal strings, as the
//// OTLP/JSON mapping requires. gloss's own HTTP and SQL attributes are
//// renamed to the OpenTelemetry semantic conventions so tools recognise
//// them; everything else is sent under its own key.

import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import gloss/meta.{type Meta}

/// A finished span, ready to encode.
pub type Span {
  Span(
    scope: String,
    name: String,
    trace_id: String,
    span_id: String,
    parent_span_id: Option(String),
    kind: Int,
    start: Timestamp,
    end: Timestamp,
    attributes: Meta,
    error: Option(String),
  )
}

/// A log record, ready to encode.
pub type Log {
  Log(
    scope: String,
    at: Timestamp,
    severity: Int,
    severity_text: String,
    body: String,
    /// The record's event name, for tracer points.
    event_name: Option(String),
    attributes: Meta,
    trace_id: Option(String),
    span_id: Option(String),
  )
}

pub const kind_internal = 1

pub const kind_server = 2

pub const kind_client = 3

/// A span from a gloss tracer span: the kind and attribute names follow
/// the semantic conventions for the sources gloss knows.
pub fn span(
  source source: String,
  name name: String,
  trace_id trace_id: String,
  span_id span_id: String,
  parent_span_id parent_span_id: Option(String),
  at at: Timestamp,
  duration elapsed: duration.Duration,
  meta meta: Meta,
  error error: Option(String),
) -> Span {
  let #(kind, attributes) = case source, name {
    "gloss.http", _ -> #(kind_server, rename(meta, http_names))
    "gloss.sql", _ -> #(kind_client, sql_attributes(meta))
    _, _ -> #(kind_internal, meta)
  }
  Span(
    scope: source,
    name:,
    trace_id:,
    span_id:,
    parent_span_id:,
    kind:,
    start: at,
    end: timestamp.add(at, elapsed),
    attributes:,
    error:,
  )
}

const http_names = [
  #("method", "http.request.method"),
  #("path", "url.path"),
  #("route", "http.route"),
  #("status", "http.response.status_code"),
  #("client_ip", "client.address"),
  #("bytes", "http.response.body.size"),
  #("protocol", "websocket.protocol"),
]

fn sql_attributes(meta: Meta) -> Meta {
  meta
  |> list.map(fn(entry) {
    case entry {
      #("driver", meta.String("postgres")) -> #(
        "db.system.name",
        meta.String("postgresql"),
      )
      #("driver", value) -> #("db.system.name", value)
      #("sql", value) -> #("db.query.text", value)
      #("rows", value) -> #("db.response.returned_rows", value)
      #("label", value) -> #("db.query.summary", value)
      other -> other
    }
  })
}

fn rename(meta: Meta, names: List(#(String, String))) -> Meta {
  list.map(meta, fn(entry) {
    case list.key_find(names, entry.0) {
      Ok(name) -> #(name, entry.1)
      Error(Nil) -> entry
    }
  })
}

/// Severity numbers and text for gloss levels: DEBUG 5, INFO 9, WARN 13,
/// ERROR 17.
pub fn severity(level: String) -> #(Int, String) {
  case level {
    "debug" -> #(5, "DEBUG")
    "info" -> #(9, "INFO")
    "warning" -> #(13, "WARN")
    _ -> #(17, "ERROR")
  }
}

/// The body for `/v1/traces`. Spans are grouped by scope, in order.
pub fn traces(resource: Meta, spans: List(Span)) -> String {
  json.object([
    #(
      "resourceSpans",
      json.preprocessed_array([
        json.object([
          #("resource", resource_json(resource)),
          #(
            "scopeSpans",
            group(spans, fn(span) { span.scope })
              |> list.map(fn(group) {
                json.object([
                  #("scope", json.object([#("name", json.string(group.0))])),
                  #("spans", json.array(group.1, span_json)),
                ])
              })
              |> json.preprocessed_array,
          ),
        ]),
      ]),
    ),
  ])
  |> json.to_string
}

/// The body for `/v1/logs`. Records are grouped by scope, in order.
pub fn logs(resource: Meta, logs: List(Log)) -> String {
  json.object([
    #(
      "resourceLogs",
      json.preprocessed_array([
        json.object([
          #("resource", resource_json(resource)),
          #(
            "scopeLogs",
            group(logs, fn(log) { log.scope })
              |> list.map(fn(group) {
                json.object([
                  #("scope", json.object([#("name", json.string(group.0))])),
                  #("logRecords", json.array(group.1, log_json)),
                ])
              })
              |> json.preprocessed_array,
          ),
        ]),
      ]),
    ),
  ])
  |> json.to_string
}

fn resource_json(resource: Meta) -> Json {
  json.object([#("attributes", attributes(resource))])
}

fn span_json(span: Span) -> Json {
  let status = case span.error {
    Some(message) ->
      json.object([#("code", json.int(2)), #("message", json.string(message))])
    None -> json.object([])
  }
  json.object(
    list.flatten([
      [
        #("traceId", json.string(span.trace_id)),
        #("spanId", json.string(span.span_id)),
      ],
      case span.parent_span_id {
        Some(parent) -> [#("parentSpanId", json.string(parent))]
        None -> []
      },
      [
        #("name", json.string(span.name)),
        #("kind", json.int(span.kind)),
        #("startTimeUnixNano", json.string(nanos(span.start))),
        #("endTimeUnixNano", json.string(nanos(span.end))),
        #("attributes", attributes(span.attributes)),
        #("status", status),
      ],
    ]),
  )
}

fn log_json(log: Log) -> Json {
  json.object(
    list.flatten([
      [
        #("timeUnixNano", json.string(nanos(log.at))),
        #("observedTimeUnixNano", json.string(nanos(log.at))),
        #("severityNumber", json.int(log.severity)),
        #("severityText", json.string(log.severity_text)),
        #("body", json.object([#("stringValue", json.string(log.body))])),
      ],
      case log.event_name {
        Some(name) -> [#("eventName", json.string(name))]
        None -> []
      },
      [#("attributes", attributes(log.attributes))],
      case log.trace_id {
        Some(id) -> [#("traceId", json.string(id))]
        None -> []
      },
      case log.span_id {
        Some(id) -> [#("spanId", json.string(id))]
        None -> []
      },
    ]),
  )
}

fn attributes(meta: Meta) -> Json {
  json.array(meta, fn(entry) {
    json.object([#("key", json.string(entry.0)), #("value", value(entry.1))])
  })
}

fn value(value: meta.Value) -> Json {
  case value {
    meta.String(s) -> json.object([#("stringValue", json.string(s))])
    meta.Int(i) -> json.object([#("intValue", json.string(int.to_string(i)))])
    meta.Float(f) -> json.object([#("doubleValue", json.float(f))])
    meta.Bool(b) -> json.object([#("boolValue", json.bool(b))])
  }
}

/// Nanoseconds since the Unix epoch, as a decimal string.
pub fn nanos(at: Timestamp) -> String {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(at)
  int.to_string(seconds * 1_000_000_000 + nanoseconds)
}

/// Items grouped by key, groups in order of first appearance and items in
/// order within each.
fn group(items: List(a), key: fn(a) -> String) -> List(#(String, List(a))) {
  list.fold(items, [], fn(groups, item) {
    let k = key(item)
    case list.key_find(groups, k) {
      Ok(members) -> list.key_set(groups, k, [item, ..members])
      Error(Nil) -> [#(k, [item]), ..groups]
    }
  })
  |> list.reverse
  |> list.map(fn(group) { #(group.0, list.reverse(group.1)) })
}

/// A hex id of the given length, or `None` when `text` isn't one.
pub fn hex_id(text: String, length: Int) -> Option(String) {
  let valid =
    string.length(text) == length
    && string.to_graphemes(text)
    |> list.all(fn(c) { string.contains("0123456789abcdef", c) })
  case valid {
    True -> Some(text)
    False -> None
  }
}

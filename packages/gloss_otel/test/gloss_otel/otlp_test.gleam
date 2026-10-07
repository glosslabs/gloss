import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import gloss/meta
import gloss_otel/internal/otlp

const trace_id = "0af7651916cd43dd8448eb211c80319c"

fn http_span() -> otlp.Span {
  otlp.span(
    source: "gloss.http",
    name: "GET /threads/:id",
    trace_id:,
    span_id: "b7ad6b7169203331",
    parent_span_id: None,
    at: timestamp.from_unix_seconds_and_nanoseconds(1_700_000_000, 5),
    duration: duration.milliseconds(12),
    meta: [
      #("method", meta.String("GET")),
      #("route", meta.String("/threads/:id")),
      #("status", meta.Int(500)),
      #("request_id", meta.String(trace_id)),
    ],
    error: Some("HTTP 500"),
  )
}

/// The items under `resource.<scopes>[].<items>[]`, flattened.
fn items(body: String, resource: String, scopes: String, items: String) {
  let assert Ok(groups) =
    json.parse(
      body,
      decode.at(
        [resource],
        decode.list(decode.at(
          [scopes],
          decode.list(decode.at([items], decode.list(decode.dynamic))),
        )),
      ),
    )
  groups |> list.flatten |> list.flatten
}

fn get(item: Dynamic, path: List(String), decoder: Decoder(a)) -> a {
  let assert Ok(value) = decode.run(item, decode.at(path, decoder))
  value
}

fn attributes(item: Dynamic) -> List(#(String, Dynamic)) {
  get(
    item,
    ["attributes"],
    decode.list({
      use key <- decode.field("key", decode.string)
      use value <- decode.field("value", decode.dynamic)
      decode.success(#(key, value))
    }),
  )
}

pub fn spans_follow_otlp_json_test() {
  let body =
    otlp.traces([#("service.name", meta.String("forum"))], [http_span()])
  let assert [span] = items(body, "resourceSpans", "scopeSpans", "spans")
  assert get(span, ["traceId"], decode.string) == trace_id
  assert get(span, ["kind"], decode.int) == 2
  // 64-bit integers are decimal strings.
  assert get(span, ["startTimeUnixNano"], decode.string)
    == "1700000000000000005"
  assert get(span, ["endTimeUnixNano"], decode.string) == "1700000000012000005"
  assert get(span, ["status", "code"], decode.int) == 2
  assert get(span, ["status", "message"], decode.string) == "HTTP 500"

  // gloss's names become semantic-convention names; others are kept.
  let span_attributes = attributes(span)
  assert list.map(span_attributes, fn(a) { a.0 })
    == [
      "http.request.method", "http.route", "http.response.status_code",
      "request_id",
    ]
  let assert Ok(status) =
    list.key_find(span_attributes, "http.response.status_code")
  assert get(status, ["intValue"], decode.string) == "500"

  let assert Ok([resource]) =
    json.parse(
      body,
      decode.at(
        ["resourceSpans"],
        decode.list(decode.at(["resource"], decode.dynamic)),
      ),
    )
  let assert Ok(name) = list.key_find(attributes(resource), "service.name")
  assert get(name, ["stringValue"], decode.string) == "forum"
}

pub fn sql_spans_are_clients_with_db_attributes_test() {
  let span =
    otlp.span(
      source: "gloss.sql",
      name: "query",
      trace_id:,
      span_id: "b7ad6b7169203331",
      parent_span_id: Some("00f067aa0ba902b7"),
      at: timestamp.from_unix_seconds(0),
      duration: duration.milliseconds(1),
      meta: [
        #("driver", meta.String("postgres")),
        #("sql", meta.String("select 1")),
        #("rows", meta.Int(1)),
      ],
      error: None,
    )
  assert span.kind == otlp.kind_client
  assert span.attributes
    == [
      #("db.system.name", meta.String("postgresql")),
      #("db.query.text", meta.String("select 1")),
      #("db.response.returned_rows", meta.Int(1)),
    ]
  let assert [encoded] =
    items(otlp.traces([], [span]), "resourceSpans", "scopeSpans", "spans")
  assert get(encoded, ["parentSpanId"], decode.string) == "00f067aa0ba902b7"
}

pub fn spans_are_grouped_by_scope_test() {
  let other = otlp.Span(..http_span(), scope: "gloss.sql")
  let body = otlp.traces([], [http_span(), other, http_span()])
  let assert Ok(scopes) =
    json.parse(
      body,
      decode.at(
        ["resourceSpans"],
        decode.list(decode.at(
          ["scopeSpans"],
          decode.list(decode.at(["scope", "name"], decode.string)),
        )),
      ),
    )
  assert scopes == [["gloss.http", "gloss.sql"]]
  assert list.length(items(body, "resourceSpans", "scopeSpans", "spans")) == 3
}

pub fn logs_follow_otlp_json_test() {
  let log =
    otlp.Log(
      scope: "gloss.logger",
      at: timestamp.from_unix_seconds(1),
      severity: 13,
      severity_text: "WARN",
      body: "slow query",
      event_name: Some("query.slow"),
      attributes: [#("ms", meta.Float(1.5))],
      trace_id: Some(trace_id),
      span_id: None,
    )
  let assert [record] =
    items(otlp.logs([], [log]), "resourceLogs", "scopeLogs", "logRecords")
  assert get(record, ["body", "stringValue"], decode.string) == "slow query"
  assert get(record, ["eventName"], decode.string) == "query.slow"
  assert get(record, ["severityNumber"], decode.int) == 13
  assert get(record, ["severityText"], decode.string) == "WARN"
  assert get(record, ["timeUnixNano"], decode.string) == "1000000000"
  assert get(record, ["observedTimeUnixNano"], decode.string) == "1000000000"
  assert get(record, ["traceId"], decode.string) == trace_id
  assert decode.run(record, decode.at(["spanId"], decode.string)) |> is_error
  let assert [#("ms", value)] = attributes(record)
  assert get(value, ["doubleValue"], decode.float) == 1.5
}

pub fn hex_ids_test() {
  assert otlp.hex_id(trace_id, 32) == Some(trace_id)
  assert otlp.hex_id("req-1", 32) == None
  assert otlp.hex_id("0AF7651916CD43DD8448EB211C80319C", 32) == None
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

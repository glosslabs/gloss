# gloss_otel

Export gloss tracer spans and logs to [OpenTelemetry](https://opentelemetry.io)
over OTLP/HTTP (JSON): to a collector, or to any service that accepts OTLP,
such as Honeycomb, Grafana Cloud or Datadog.

```gleam
import gleam/httpc
import gloss/logger
import gloss/tracer
import gloss_otel

let assert Ok(otel) =
  gloss_otel.config("http://localhost:4318")
  |> gloss_otel.service_name("forum")
  |> gloss_otel.service_version("1.4.0")
  |> gloss_otel.start(httpc.send)

let tracer = tracer.new() |> tracer.handle(gloss_otel.handler(otel))
let log = logger.stack([logger.stderr(), gloss_otel.logger(otel)])

// At shutdown, send what is still buffered:
let _ = gloss_otel.flush(otel, duration.seconds(5))
```

## What gets exported

| gloss | OpenTelemetry |
|---|---|
| `tracer.Span` | A span on `/v1/traces`, with its trace, parent, start and end, `meta` as attributes, and status Error when it failed. `source` is the instrumentation scope |
| `tracer.Point` | A log record on `/v1/logs`, with its level as severity, its name as body and event name, and the trace and span it happened in |
| Entries written to `gloss_otel.logger(otel)` | Log records, tied to their request's trace by the `request_id` (or `trace_id` and `span_id`) meta that gloss/http adds to each handler's logger |

gloss's own spans use the semantic conventions, so tracing tools show them
properly:

| Source | Kind | Attributes |
|---|---|---|
| `gloss.http` | Server | `http.request.method`, `url.path`, `http.route`, `http.response.status_code`, `client.address`, `http.response.body.size` |
| `gloss.sql` | Client | `db.system.name`, `db.query.text`, `db.response.returned_rows`, `db.query.summary` |
| anything else | Internal | `meta` as it is |

If the tracer also forwards events to a logger with `logger.trace_handler`,
don't put `gloss_otel.logger` in that logger as well, or points are sent
twice. Give handlers a separate logger that includes it (see the forum's
`app/tracing.gleam`).

## Configuration

| Setter | Default | |
|---|---|---|
| `service_name` | `unknown_service:beam` | The `service.name` tools group by |
| `service_version` | none | `service.version` |
| `resource` | none | More resource attributes, e.g. `deployment.environment.name` |
| `header` | none | A header on every request, such as an API key |
| `max_batch` | 512 | Spans or records per request |
| `interval` | 5 seconds | The longest anything waits for its batch to fill |
| `max_queue` | 8 | Requests waiting to be sent before the oldest is dropped |
| `named` | none | Register the exporter so `from_name` reaches it across restarts |

## Sending

`start` and `supervised` take the function that performs the HTTP POST,
typically `httpc.send`, so the package has no HTTP client dependency and tests
can record requests instead. Sending happens in its own process: the tracer
handler and log channel cost one message send and never block.

One request is in flight at a time. A `429`, `502`, `503`, `504` or transport
error pauses sending, for as long as `Retry-After` asks or else for 1, 2, 4 ...
up to 30 seconds, and then the request is tried again. Other failures drop the
request. When the queue is full its oldest request is dropped, so memory stays
bounded whatever the collector does.

To try it locally, run a collector that prints what it receives:

```sh
docker run -p 4318:4318 otel/opentelemetry-collector-contrib
```

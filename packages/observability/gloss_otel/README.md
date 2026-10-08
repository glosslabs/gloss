# gloss_otel

Exports gloss tracer spans and logs to OpenTelemetry over OTLP/HTTP, to a
collector or any service that accepts OTLP. Imported as `gloss/otel`; it
takes the function that sends HTTP requests, such as `httpc.send`.

```gleam
import gloss/otel

let assert Ok(exporter) =
  otel.config("http://localhost:4318")
  |> otel.service_name("forum")
  |> otel.start(httpc.send)

let tracer = tracer.new() |> tracer.handle(otel.handler(exporter))
// At shutdown:
let _ = otel.flush(exporter, duration.seconds(5))
```

- Spans go to `/v1/traces`; points and log entries go to `/v1/logs`, tied to their trace.
- HTTP and SQL spans use the OpenTelemetry semantic conventions.
- Batched, with a bounded queue and backoff when the collector is busy or down.

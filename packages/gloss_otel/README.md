# gloss_otel

Exports gloss tracer spans and logs to OpenTelemetry over OTLP/HTTP, to a
collector or any service that accepts OTLP. It takes the function that sends
HTTP requests, such as `httpc.send`.

```gleam
let assert Ok(otel) =
  gloss_otel.config("http://localhost:4318")
  |> gloss_otel.service_name("forum")
  |> gloss_otel.start(httpc.send)

let tracer = tracer.new() |> tracer.handle(gloss_otel.handler(otel))
// At shutdown:
let _ = gloss_otel.flush(otel, duration.seconds(5))
```

- Spans go to `/v1/traces`; points and log entries go to `/v1/logs`, tied to their trace.
- HTTP and SQL spans use the OpenTelemetry semantic conventions.
- Batched, with a bounded queue and backoff when the collector is busy or down.

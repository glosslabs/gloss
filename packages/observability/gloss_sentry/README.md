# gloss_sentry

Reports gloss tracer failures, log entries and process crashes to
[Sentry](https://sentry.io). Imported as `gloss/sentry`; it takes the
function that sends HTTP requests, such as `httpc.send`.

```gleam
import gloss/sentry

let assert Ok(reporter) =
  sentry.config(dsn)
  |> sentry.environment("production")
  |> sentry.start(httpc.send)

let tracer = tracer.new() |> tracer.handle(sentry.handler(reporter))
let assert Ok(Nil) = sentry.report_crashes(reporter)
```

- Failed spans and error points become events; other tracer events become breadcrumbs.
- `capture` and `capture_error` for handled problems; `logger` sends entries to Sentry Logs.
- Sending happens in its own process, with a bounded queue and Sentry's rate limits respected.

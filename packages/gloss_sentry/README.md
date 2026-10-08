# gloss_sentry

Reports gloss tracer failures, log entries and process crashes to
[Sentry](https://sentry.io). It takes the function that sends HTTP requests,
such as `httpc.send`.

```gleam
let assert Ok(sentry) =
  gloss_sentry.config(dsn)
  |> gloss_sentry.environment("production")
  |> gloss_sentry.start(httpc.send)

let tracer = tracer.new() |> tracer.handle(gloss_sentry.handler(sentry))
let assert Ok(Nil) = gloss_sentry.report_crashes(sentry)
```

- Failed spans and error points become events; other tracer events become breadcrumbs.
- `capture` and `capture_error` for handled problems; `logger` sends entries to Sentry Logs.
- Sending happens in its own process, with a bounded queue and Sentry's rate limits respected.

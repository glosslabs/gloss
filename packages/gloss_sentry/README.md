# gloss_sentry

Report gloss tracer failures and explicit captures to [Sentry](https://sentry.io).

```gleam
import gleam/httpc
import gloss/tracer
import gloss_sentry

let assert Ok(sentry) =
  gloss_sentry.config(dsn)
  |> gloss_sentry.environment("production")
  |> gloss_sentry.release("1.4.0")
  |> gloss_sentry.start(httpc.send)

let tracer = tracer.new() |> tracer.handle(gloss_sentry.handler(sentry))
gloss_sentry.capture(sentry, "payment declined", [#("order", meta.String(id))])
```

## What gets reported

| Tracer event | Sentry |
|---|---|
| `Span` with an error | Exception grouped by `source.name`, with duration and meta |
| `Point` at `Error` or `Warning` | Message event at that level |
| Everything else | Kept as a breadcrumb for the next event |
| `capture` / `capture_error` | Message or exception event from the application |

Sending happens in its own process. The tracer handler and `capture` cost one
message send and never block or panic. One envelope is in flight at a time;
the rest wait in a bounded queue that drops its oldest entry when full. Rate
limits from Sentry (`429`, `X-Sentry-Rate-Limits`) pause sending for the time
asked and drop events meanwhile; transport errors and 5xx pause for five
seconds. Nothing is retried, so memory stays bounded whatever Sentry does.

The HTTP POST is performed by the function you pass to `start`, usually
`httpc.send`, so this package has no HTTP client dependency and tests can
record requests instead.

## Supervision

`supervised` returns a child specification for `gleam/otp`. Pair it with
`named` and `from_name` so handlers built before the tree starts keep working
across restarts.

## Planned: OTP crash reports

A later release adds `install_logger_handler`, an Erlang `logger` handler
that forwards process crash reports (including Gleam panics, with a `.gleam`
frame) to Sentry. It will require a sender started with `named`.

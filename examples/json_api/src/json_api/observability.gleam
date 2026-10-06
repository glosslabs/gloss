//// Where logs and trace events go.

import gleam/httpc
import gleam/option.{None, Some}
import gloss/logger.{type Logger}
import gloss/tracer.{type Tracer}
import gloss_sentry
import json_api/config.{type Config}

/// Log to stderr, and log every trace event: each request's span becomes
/// one access-log line. With `SENTRY_DSN` set, failed requests are also
/// reported to Sentry.
pub fn setup(config: Config) -> #(Logger, Tracer) {
  let log = logger.stderr()
  let tracer =
    tracer.new()
    |> tracer.handle(logger.trace_handler(log))
    |> with_sentry(config)
  #(log, tracer)
}

fn with_sentry(tracer: Tracer, config: Config) -> Tracer {
  case config.sentry_dsn {
    None -> tracer
    Some(dsn) -> {
      let assert Ok(sentry) =
        gloss_sentry.config(dsn)
        |> gloss_sentry.environment(config.environment)
        |> gloss_sentry.start(httpc.send)
      tracer |> tracer.handle(gloss_sentry.handler(sentry))
    }
  }
}

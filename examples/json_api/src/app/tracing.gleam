//// Where trace events go.

import gleam/option.{type Option, None, Some}
import gloss/logger.{type Logger}
import gloss/sentry.{type Sentry}
import gloss/tracer.{type Tracer}

/// Log every event, so each request's span is one access-log line.
pub fn with_logger(tracer: Tracer, log: Logger) -> Tracer {
  tracer |> tracer.handle(logger.trace_handler(log))
}

/// Report failed spans and error points to Sentry, when it is configured.
pub fn with_sentry(tracer: Tracer, sentry: Option(Sentry)) -> Tracer {
  case sentry {
    Some(sentry) -> tracer |> tracer.handle(sentry.handler(sentry))
    None -> tracer
  }
}

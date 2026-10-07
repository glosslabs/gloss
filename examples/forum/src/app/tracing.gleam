//// Where trace events go.

import gleam/option.{type Option, None, Some}
import gloss/logger.{type Logger}
import gloss/tracer.{type Tracer}
import gloss_otel.{type Otel}
import gloss_sentry.{type Sentry}

/// Log every event, so each request's span is one access-log line.
pub fn with_logger(tracer: Tracer, log: Logger) -> Tracer {
  tracer |> tracer.handle(logger.trace_handler(log))
}

/// Report failed spans and error points to Sentry, when it is configured.
pub fn with_sentry(tracer: Tracer, sentry: Option(Sentry)) -> Tracer {
  case sentry {
    Some(sentry) -> tracer |> tracer.handle(gloss_sentry.handler(sentry))
    None -> tracer
  }
}

/// Export every span and point, when OpenTelemetry is configured.
pub fn with_otel(tracer: Tracer, otel: Option(Otel)) -> Tracer {
  case otel {
    Some(otel) -> tracer |> tracer.handle(gloss_otel.handler(otel))
    None -> tracer
  }
}

/// The logger handlers write to: `log`, and OpenTelemetry when it is
/// configured. Tracer events reach OpenTelemetry through `with_otel`, so
/// this one is kept apart from the logger `with_logger` writes events to.
pub fn handler_logger(log: Logger, otel: Option(Otel)) -> Logger {
  case otel {
    Some(otel) -> logger.stack([log, gloss_otel.logger(otel)])
    None -> log
  }
}

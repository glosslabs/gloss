//// Where trace events go.

import gleam/option.{type Option, None, Some}
import gloss/http/debug_bar.{type DebugBar}
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

/// Record every span and point for the debug bar, in development.
pub fn with_debug_bar(tracer: Tracer, bar: Option(DebugBar)) -> Tracer {
  case bar {
    Some(bar) -> tracer |> tracer.handle(debug_bar.handler(bar))
    None -> tracer
  }
}

/// The logger handlers write to: `log`, plus OpenTelemetry and the debug
/// bar when they are on. Tracer events reach those through `with_otel` and
/// `with_debug_bar`, so this one is kept apart from the logger
/// `with_logger` writes events to.
pub fn handler_logger(
  log: Logger,
  otel otel: Option(Otel),
  debug_bar bar: Option(DebugBar),
) -> Logger {
  let channels =
    [
      option.map(otel, gloss_otel.logger),
      option.map(bar, debug_bar.logger),
    ]
    |> option.values
  case channels {
    [] -> log
    _ -> logger.stack([log, ..channels])
  }
}

//// Where logs, trace events and failures go.
////
//// Log entries are split by level: debug and info go to stdout and
//// `log/app.log`, warnings and errors to stderr and `log/error.log`. Both
//// files rotate by size. With `SENTRY_DSN` set, info and above also go to
//// Sentry Logs. Every trace event is logged, so each request's span is one
//// access-log line, and failed requests are reported to Sentry as errors.

import app/config.{type Config}
import gleam/httpc
import gleam/option.{type Option, None, Some}
import gloss/logger.{type Logger}
import gloss/logger/file
import gloss/tracer.{type Tracer}
import gloss_sentry.{type Sentry}

pub fn setup(config: Config) -> #(Logger, Tracer) {
  let sentry = start_sentry(config)
  let log = logger.stack([console(), files(config), sentry_logs(sentry)])
  let tracer =
    tracer.new()
    |> with_logger(log)
    |> with_sentry(sentry)
  #(log, tracer)
}

// --- Log channels ------------------------------------------------------------

/// Debug and info to stdout; warnings and errors to stderr.
fn console() -> Logger {
  split(logger.stdout(), logger.stderr())
}

/// The same split into `app.log` and `error.log` under `LOG_DIR`, each
/// rotated at 10 MB with 5 old files kept.
fn files(config: Config) -> Logger {
  let assert Ok(app) = file.config(config.log_dir <> "/app.log") |> file.start
  let assert Ok(errors) =
    file.config(config.log_dir <> "/error.log") |> file.start
  split(app, errors)
}

/// Info and above to Sentry Logs, when Sentry is configured.
fn sentry_logs(sentry: Option(Sentry)) -> Logger {
  case sentry {
    Some(sentry) -> gloss_sentry.logger(sentry) |> logger.min_level(logger.Info)
    None -> logger.discard()
  }
}

fn split(info: Logger, problems: Logger) -> Logger {
  logger.stack([
    info |> logger.max_level(logger.Info),
    problems |> logger.min_level(logger.Warning),
  ])
}

// --- Tracer handlers ---------------------------------------------------------

fn with_logger(tracer: Tracer, log: Logger) -> Tracer {
  tracer |> tracer.handle(logger.trace_handler(log))
}

fn with_sentry(tracer: Tracer, sentry: Option(Sentry)) -> Tracer {
  case sentry {
    Some(sentry) -> tracer |> tracer.handle(gloss_sentry.handler(sentry))
    None -> tracer
  }
}

fn start_sentry(config: Config) -> Option(Sentry) {
  case config.sentry_dsn {
    None -> None
    Some(dsn) -> {
      let assert Ok(sentry) =
        gloss_sentry.config(dsn)
        |> gloss_sentry.environment(config.environment)
        |> gloss_sentry.start(httpc.send)
      Some(sentry)
    }
  }
}

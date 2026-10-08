//// Where log entries go. Entries are split by level: debug and info to
//// stdout and `app.log`, warnings and errors to stderr and `error.log`.

import app/config.{type Config}
import gleam/option.{type Option, None, Some}
import gloss/logger.{type Logger}
import gloss/logger/file
import gloss/sentry.{type Sentry}

/// Debug and info to stdout; warnings and errors to stderr.
pub fn console() -> Logger {
  split(logger.stdout(), logger.stderr())
}

/// The same split into `app.log` and `error.log` under `LOG_DIR`, each
/// rotated at 10 MB with 5 old files kept.
pub fn files(config: Config) -> Logger {
  let assert Ok(app) = file.config(config.log_dir <> "/app.log") |> file.start
  let assert Ok(errors) =
    file.config(config.log_dir <> "/error.log") |> file.start
  split(app, errors)
}

/// Info and above to Sentry Logs, when Sentry is configured.
pub fn to_sentry(sentry: Option(Sentry)) -> Logger {
  case sentry {
    Some(sentry) -> sentry.logger(sentry) |> logger.min_level(logger.Info)
    None -> logger.discard()
  }
}

fn split(info: Logger, problems: Logger) -> Logger {
  logger.stack([
    info |> logger.max_level(logger.Info),
    problems |> logger.min_level(logger.Warning),
  ])
}

import app/config.{type Config}
import gloss/logger.{type Logger}
import gloss/logger/file

pub fn default(config: Config) -> Logger {
  logger.stack([console(), files(config)])
}

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

fn split(info: Logger, problems: Logger) -> Logger {
  logger.stack([
    info |> logger.max_level(logger.Info),
    problems |> logger.min_level(logger.Warning),
  ])
}

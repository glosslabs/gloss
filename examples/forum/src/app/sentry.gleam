//// Error reporting to Sentry, when `SENTRY_DSN` is set.

import app/config.{type Config}
import gleam/httpc
import gleam/option.{type Option, None, Some}
import gloss/sentry.{type Sentry}

pub fn start(config: Config) -> Option(Sentry) {
  case config.sentry_dsn {
    None -> None
    Some(dsn) -> {
      let assert Ok(reporter) =
        sentry.config(dsn)
        |> sentry.environment(config.environment)
        |> sentry.start(httpc.send)
      // Crashed processes, not only failed requests and tasks.
      let assert Ok(Nil) = sentry.report_crashes(reporter)
      Some(reporter)
    }
  }
}

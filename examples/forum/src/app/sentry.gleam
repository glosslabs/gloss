//// Error reporting to Sentry, when `SENTRY_DSN` is set.

import app/config.{type Config}
import gleam/httpc
import gleam/option.{type Option, None, Some}
import gloss_sentry.{type Sentry}

pub fn start(config: Config) -> Option(Sentry) {
  case config.sentry_dsn {
    None -> None
    Some(dsn) -> {
      let assert Ok(sentry) =
        gloss_sentry.config(dsn)
        |> gloss_sentry.environment(config.environment)
        |> gloss_sentry.start(httpc.send)
      // Crashed processes, not only failed requests and tasks.
      let assert Ok(Nil) = gloss_sentry.report_crashes(sentry)
      Some(sentry)
    }
  }
}

//// Error reporting to Sentry.

import gleam/httpc
import gleam/option.{type Option, None, Some}
import gloss_sentry.{type Sentry}

pub fn start(dsn: Option(String), environment: String) -> Option(Sentry) {
  case dsn {
    None -> None
    Some(dsn) -> {
      let assert Ok(sentry) =
        gloss_sentry.config(dsn)
        |> gloss_sentry.environment(environment)
        |> gloss_sentry.start(httpc.send)
      Some(sentry)
    }
  }
}

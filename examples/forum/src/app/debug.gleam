//// The debug bar at the foot of each page, in development only.

import app/config.{type Config}
import gleam/option.{type Option, None, Some}
import gloss/http/debug_bar.{type DebugBar}
import gloss/http/server.{type Builder}

pub fn start(config: Config) -> Option(DebugBar) {
  case config.environment {
    "development" -> {
      let assert Ok(bar) = debug_bar.start()
      Some(bar)
    }
    _ -> None
  }
}

/// Show the bar on the server's HTML pages.
pub fn with_panel(
  builder: Builder(state),
  bar: Option(DebugBar),
) -> Builder(state) {
  case bar {
    Some(bar) -> builder |> server.with(debug_bar.middleware(bar))
    None -> builder
  }
}

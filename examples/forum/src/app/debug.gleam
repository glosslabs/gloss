//// Development aids: the debug bar at the foot of each page, and reloading
//// when source files change. Both are on only in development.

import app/config.{type Config}
import gleam/option.{type Option, None, Some}
import gloss/http/debug_bar.{type DebugBar}
import gloss/http/server.{type Builder}
import gloss/reload.{type Reloader}
import gloss/tracer.{type Tracer}

pub fn start(config: Config) -> Option(DebugBar) {
  case config.environment {
    "development" -> {
      let assert Ok(bar) = debug_bar.start()
      Some(bar)
    }
    _ -> None
  }
}

/// Rebuild and reload code when `src` or `priv` changes, refreshing pages.
pub fn reloader(config: Config, tracer: Tracer) -> Option(Reloader) {
  case config.environment {
    "development" -> {
      let assert Ok(reloader) =
        reload.new() |> reload.tracer(tracer) |> reload.start
      Some(reloader)
    }
    _ -> None
  }
}

/// Add the bar and live reloading to the server's HTML pages.
pub fn with_pages(
  builder: Builder(state),
  bar: Option(DebugBar),
  reloader: Option(Reloader),
) -> Builder(state) {
  let builder = case bar {
    Some(bar) -> builder |> server.with(debug_bar.middleware(bar))
    None -> builder
  }
  case reloader {
    Some(reloader) -> builder |> server.with(reload.middleware(reloader))
    None -> builder
  }
}

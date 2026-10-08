//// Traces and logs to OpenTelemetry, when `OTEL_EXPORTER_OTLP_ENDPOINT` is
//// set.

import app/config.{type Config}
import gleam/httpc
import gleam/option.{type Option, None, Some}
import gleam/time/duration
import gloss/meta
import gloss/otel.{type Otel}

pub fn start(config: Config) -> Option(Otel) {
  case config.otel_endpoint {
    None -> None
    Some(endpoint) -> {
      let assert Ok(exporter) =
        otel.config(endpoint)
        |> otel.service_name("forum")
        |> otel.resource([
          #("deployment.environment.name", meta.String(config.environment)),
        ])
        |> otel.start(httpc.send)
      Some(exporter)
    }
  }
}

/// Send the last traces and logs before the node stops.
pub fn flush(exporter: Option(Otel)) -> Nil {
  case exporter {
    Some(exporter) -> {
      let _ = otel.flush(exporter, duration.seconds(5))
      Nil
    }
    None -> Nil
  }
}

//// Traces and logs to OpenTelemetry, when `OTEL_EXPORTER_OTLP_ENDPOINT` is
//// set.

import app/config.{type Config}
import gleam/httpc
import gleam/option.{type Option, None, Some}
import gloss/meta
import gloss_otel.{type Otel}

pub fn start(config: Config) -> Option(Otel) {
  case config.otel_endpoint {
    None -> None
    Some(endpoint) -> {
      let assert Ok(otel) =
        gloss_otel.config(endpoint)
        |> gloss_otel.service_name("forum")
        |> gloss_otel.resource([
          #("deployment.environment.name", meta.String(config.environment)),
        ])
        |> gloss_otel.start(httpc.send)
      Some(otel)
    }
  }
}

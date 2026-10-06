import envoy
import gleam/int
import gleam/option.{type Option}
import gleam/result

pub type Config {
  Config(
    port: Int,
    environment: String,
    sentry_dsn: Option(String),
    /// The bearer token that authenticates API clients.
    api_token: String,
    /// Where `app.log` and `error.log` are written.
    log_dir: String,
  )
}

/// Read `PORT`, `APP_ENV`, `SENTRY_DSN`, `API_TOKEN` and `LOG_DIR`, with
/// development defaults.
pub fn from_env() -> Config {
  Config(
    port: envoy.get("PORT") |> result.try(int.parse) |> result.unwrap(4000),
    environment: envoy.get("APP_ENV") |> result.unwrap("development"),
    sentry_dsn: envoy.get("SENTRY_DSN") |> option.from_result,
    api_token: envoy.get("API_TOKEN") |> result.unwrap("dev"),
    log_dir: envoy.get("LOG_DIR") |> result.unwrap("log"),
  )
}

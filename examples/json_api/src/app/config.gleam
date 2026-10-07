import envoy
import gleam/int
import gleam/option.{type Option, None}
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

/// The settings for local development.
pub fn defaults() -> Config {
  Config(
    port: 4000,
    environment: "development",
    sentry_dsn: None,
    api_token: "dev",
    log_dir: "log",
  )
}

/// The defaults, with `PORT`, `APP_ENV`, `SENTRY_DSN`, `API_TOKEN` and
/// `LOG_DIR` applied over them where they are set.
pub fn from_env() -> Config {
  let defaults = defaults()
  Config(
    port: envoy.get("PORT")
      |> result.try(int.parse)
      |> result.unwrap(defaults.port),
    environment: envoy.get("APP_ENV") |> result.unwrap(defaults.environment),
    sentry_dsn: envoy.get("SENTRY_DSN")
      |> option.from_result
      |> option.or(defaults.sentry_dsn),
    api_token: envoy.get("API_TOKEN") |> result.unwrap(defaults.api_token),
    log_dir: envoy.get("LOG_DIR") |> result.unwrap(defaults.log_dir),
  )
}

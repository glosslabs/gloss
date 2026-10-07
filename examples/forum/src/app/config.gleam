import envoy
import gleam/int
import gleam/option.{type Option, None}
import gleam/result

pub type Config {
  Config(
    port: Int,
    /// `development` relaxes the session cookie's `Secure` flag so it works
    /// over plain HTTP on localhost.
    environment: String,
    /// Where uploaded avatars are kept.
    data_dir: String,
    /// Where `app.log` and `error.log` are written.
    log_dir: String,
    sentry_dsn: Option(String),
  )
}

/// The settings for local development.
pub fn defaults() -> Config {
  Config(
    port: 4000,
    environment: "development",
    data_dir: "data",
    log_dir: "log",
    sentry_dsn: None,
  )
}

/// The defaults, with `PORT`, `APP_ENV`, `DATA_DIR`, `LOG_DIR` and
/// `SENTRY_DSN` applied over them where they are set.
pub fn from_env() -> Config {
  let defaults = defaults()
  Config(
    port: envoy.get("PORT")
      |> result.try(int.parse)
      |> result.unwrap(defaults.port),
    environment: envoy.get("APP_ENV") |> result.unwrap(defaults.environment),
    data_dir: envoy.get("DATA_DIR") |> result.unwrap(defaults.data_dir),
    log_dir: envoy.get("LOG_DIR") |> result.unwrap(defaults.log_dir),
    sentry_dsn: envoy.get("SENTRY_DSN")
      |> option.from_result
      |> option.or(defaults.sentry_dsn),
  )
}

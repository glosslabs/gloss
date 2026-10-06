import envoy
import gleam/int
import gleam/result

pub type Config {
  Config(
    port: Int,
    /// `development` relaxes the session cookie's `Secure` flag so it works
    /// over plain HTTP on localhost.
    environment: String,
    /// Where uploaded avatars are kept.
    data_dir: String,
  )
}

/// Read `PORT`, `APP_ENV` and `DATA_DIR`, with development defaults.
pub fn from_env() -> Config {
  Config(
    port: envoy.get("PORT") |> result.try(int.parse) |> result.unwrap(4000),
    environment: envoy.get("APP_ENV") |> result.unwrap("development"),
    data_dir: envoy.get("DATA_DIR") |> result.unwrap("data"),
  )
}

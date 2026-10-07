//// A Postgres driver for `gloss/sql`, speaking the wire protocol directly.
////
//// ```gleam
//// let assert Ok(config) = pg.from_url("postgres://app:secret@db:5432/app")
//// let assert Ok(db) = sql.new(pg.driver(config)) |> sql.start
//// ```
////
//// Placeholders are `$1`, `$2`, ... Each argument is sent as text (bytes as
//// binary) and the server infers its type from the statement, so
//// `sql.Text` serves `uuid`, `json` or `numeric` columns, and `sql.Array`
//// serves `= any($1)`.
////
//// ## Column values
////
//// | Postgres                         | Gleam value                      |
//// |----------------------------------|----------------------------------|
//// | `bool`                           | `Bool`                           |
//// | `smallint`, `integer`, `bigint`  | `Int`                            |
//// | `real`, `double precision`       | `Float`                          |
//// | `bytea`                          | `BitArray`                       |
//// | `date`                           | `calendar.Date` (`sql.date_decoder`) |
//// | `time`                           | `calendar.TimeOfDay` (`sql.time_decoder`) |
//// | `timestamp`, `timestamptz`       | `Timestamp` (`sql.timestamp_decoder`) |
//// | arrays of the above              | `List`                           |
//// | everything else                  | `String` in Postgres's text form |
////
//// "Everything else" includes `text`, `uuid`, `json`, `jsonb`, `numeric`
//// and enums, and also values Gleam can't hold, such as `NaN` or an
//// `infinity` timestamp. `timestamp` without a time zone is read as UTC.
////
//// ## Authentication and TLS
////
//// SCRAM-SHA-256, MD5 and cleartext passwords are supported. TLS is off by
//// default; turn it on with `ssl` or `?sslmode=` in the URL. `SslVerified`
//// checks the server's certificate against the system's CA store.
////
//// ## Errors
////
//// Server errors become `sql.Error`s by SQLSTATE: `23505` is
//// `UniqueViolation`, `23503` `ForeignKeyViolation`, `23502`
//// `NotNullViolation` and `23514` `CheckViolation`. Others are
//// `QueryFailed` with the SQLSTATE as the code.
////
//// Statements are parsed on every run; there is no prepared statement
//// cache yet. `LISTEN`/`NOTIFY` and `COPY` are not supported.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/uri
import gloss/internal/pg_connection as connection
import gloss/sql

/// Where and how to connect. Build one with `new` or `from_url` and the
/// setters, then give `driver(config)` to `sql.new`.
pub opaque type Config {
  Config(
    host: String,
    port: Int,
    user: String,
    password: Option(String),
    database: String,
    ssl: Ssl,
    application_name: String,
    connect_timeout: Duration,
    parameters: List(#(String, String)),
  )
}

pub type Ssl {
  /// Plain TCP.
  SslDisabled
  /// TLS when the server offers it, otherwise plain TCP.
  SslPreferred
  /// TLS without checking the server's certificate.
  SslRequired
  /// TLS with the certificate checked against the system's CA store and
  /// the host name.
  SslVerified
}

/// `postgres@localhost:5432/postgres`, without TLS or a password, with a
/// 5 second connect timeout.
pub fn new() -> Config {
  Config(
    host: "localhost",
    port: 5432,
    user: "postgres",
    password: None,
    database: "postgres",
    ssl: SslDisabled,
    application_name: "gloss",
    connect_timeout: duration.seconds(5),
    parameters: [],
  )
}

/// Read a connection URL:
/// `postgres://user:password@host:port/database?sslmode=require`.
///
/// `sslmode` may be `disable`, `allow` or `prefer` (`SslPreferred`),
/// `require`, `verify-ca` or `verify-full` (`SslVerified`).
/// `application_name` and `connect_timeout` (seconds) are understood too,
/// and any other query parameter is sent to the server as a run-time
/// parameter, e.g. `?search_path=app`.
pub fn from_url(url: String) -> Result(Config, Nil) {
  use parsed <- result.try(uri.parse(url))
  use Nil <- result.try(case parsed.scheme {
    Some("postgres") | Some("postgresql") -> Ok(Nil)
    _ -> Error(Nil)
  })
  let config = new()
  let config = case parsed.host {
    Some("") | None -> config
    Some(host) -> Config(..config, host:)
  }
  let config = case parsed.port {
    Some(port) -> Config(..config, port:)
    None -> config
  }
  use config <- result.try(case parsed.userinfo {
    None -> Ok(config)
    Some(userinfo) ->
      case string.split_once(userinfo, ":") {
        Ok(#(user, password)) -> {
          use user <- result.try(uri.percent_decode(user))
          use password <- result.map(uri.percent_decode(password))
          Config(..config, user:, password: Some(password))
        }
        Error(Nil) ->
          uri.percent_decode(userinfo)
          |> result.map(fn(user) { Config(..config, user:) })
      }
  })
  use config <- result.try(case parsed.path {
    "" | "/" -> Ok(config)
    "/" <> database ->
      uri.percent_decode(database)
      |> result.map(fn(database) { Config(..config, database:) })
    _ -> Error(Nil)
  })
  let query =
    option.map(parsed.query, uri.parse_query)
    |> option.unwrap(Ok([]))
  use query <- result.try(query)
  list.try_fold(query, config, fn(config, pair) {
    case pair {
      #("sslmode", "disable") -> Ok(Config(..config, ssl: SslDisabled))
      #("sslmode", "allow") | #("sslmode", "prefer") ->
        Ok(Config(..config, ssl: SslPreferred))
      #("sslmode", "require") -> Ok(Config(..config, ssl: SslRequired))
      #("sslmode", "verify-ca") | #("sslmode", "verify-full") ->
        Ok(Config(..config, ssl: SslVerified))
      #("sslmode", _) -> Error(Nil)
      #("application_name", name) ->
        Ok(Config(..config, application_name: name))
      #("connect_timeout", seconds) ->
        int.parse(seconds)
        |> result.map(fn(s) {
          Config(..config, connect_timeout: duration.seconds(s))
        })
      #(name, value) -> Ok(parameter(config, name, value))
    }
  })
}

pub fn host(config: Config, host: String) -> Config {
  Config(..config, host:)
}

pub fn port(config: Config, port: Int) -> Config {
  Config(..config, port:)
}

pub fn user(config: Config, user: String) -> Config {
  Config(..config, user:)
}

pub fn password(config: Config, password: String) -> Config {
  Config(..config, password: Some(password))
}

pub fn database(config: Config, database: String) -> Config {
  Config(..config, database:)
}

pub fn ssl(config: Config, ssl: Ssl) -> Config {
  Config(..config, ssl:)
}

/// Shown in `pg_stat_activity`. Defaults to `"gloss"`.
pub fn application_name(config: Config, name: String) -> Config {
  Config(..config, application_name: name)
}

/// How long opening a connection, including TLS and authentication, may
/// take.
pub fn connect_timeout(config: Config, timeout: Duration) -> Config {
  Config(..config, connect_timeout: timeout)
}

/// A run-time parameter set on every connection, e.g.
/// `pg.parameter(config, "search_path", "app")`. `DateStyle`, `TimeZone`
/// and `client_encoding` are fixed by the driver and can't be changed.
pub fn parameter(config: Config, name: String, value: String) -> Config {
  Config(..config, parameters: list.append(config.parameters, [#(name, value)]))
}

/// The driver to give to `sql.new`.
pub fn driver(config: Config) -> sql.Driver {
  let settings =
    connection.Settings(
      host: config.host,
      port: config.port,
      user: config.user,
      password: config.password,
      database: config.database,
      tls: case config.ssl {
        SslDisabled -> connection.NoTls
        SslPreferred -> connection.PreferTls
        SslRequired -> connection.RequireTls
        SslVerified -> connection.VerifyTls
      },
      connect_timeout: duration.to_milliseconds(config.connect_timeout),
      parameters: [
        #("application_name", config.application_name),
        ..list.filter(config.parameters, fn(p) { !fixed(p.0) })
      ],
    )
  sql.Driver(
    name: "postgres",
    placeholder: fn(n) { "$" <> int.to_string(n) },
    connect: fn() {
      use socket <- result.map(connection.connect(settings))
      sql.Connection(
        run: fn(text, args, timeout) {
          connection.run(socket, text, args, timeout)
        },
        script: fn(text, timeout) { connection.script(socket, text, timeout) },
        alive: fn() { connection.alive(socket) },
        transfer: fn(pid) { connection.transfer(socket, pid) },
        close: fn() { connection.close(socket) },
      )
    },
  )
}

/// Parameters the codec depends on.
fn fixed(name: String) -> Bool {
  case string.lowercase(name) {
    "datestyle" | "timezone" | "client_encoding" | "user" | "database" -> True
    _ -> False
  }
}

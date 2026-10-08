//// A MySQL driver for `gloss/sql`, speaking the client/server protocol
//// directly.
////
//// ```gleam
//// let assert Ok(config) = mysql.from_url("mysql://app:secret@db:3306/app")
//// let assert Ok(db) = pool.new(mysql.driver(config)) |> pool.start
////
//// sql.query("select id, email from users where id = ?")
//// |> sql.bind(sql.Int(id))
//// |> sql.returning(user)
//// |> pool.one(db, _)
//// ```
////
//// Placeholders are `?`. Statements with arguments run as prepared
//// statements over the binary protocol, so values are typed on the wire,
//// never spliced into SQL text.
////
//// ## Column values
////
//// | MySQL                                       | Gleam value                         |
//// |---------------------------------------------|-------------------------------------|
//// | `TINYINT(1)` (`BOOLEAN`)                    | `Bool`                              |
//// | other integers, `YEAR`                      | `Int`                               |
//// | `FLOAT`, `DOUBLE`                           | `Float`                             |
//// | `DECIMAL`                                   | `String`, exactly as stored         |
//// | `DATE`                                      | `calendar.Date` (`sql.date_decoder`) |
//// | `DATETIME`, `TIMESTAMP`                     | `Timestamp` (`sql.timestamp_decoder`) |
//// | `TIME` within a day                         | `calendar.TimeOfDay` (`sql.time_decoder`) |
//// | `BINARY`, `VARBINARY`, `BLOB`s, `BIT`       | `BitArray`                          |
//// | `CHAR`, `VARCHAR`, `TEXT`s, `ENUM`, `SET`, `JSON` | `String`                      |
////
//// `FLOAT` columns hold single-precision values, so `1.1` comes back as
//// `1.100000023841858`; use `DOUBLE` or `DECIMAL` for exact values. Values
//// Gleam can't hold come back as text: zero dates (`0000-00-00`) and `TIME`
//// durations that are negative or past 24 hours.
////
//// ## Time zones
////
//// Every connection runs `SET time_zone = '+00:00'`, so `TIMESTAMP` columns
//// are read and written in UTC. `DATETIME` has no time zone; the driver
//// treats it as UTC too. Fractional seconds are kept to microseconds,
//// MySQL's precision.
////
//// ## Arguments
////
//// `sql.Array` is refused: MySQL has no array type. `sql.Int`s beyond 64
//// bits are sent as text, which `DECIMAL` columns accept.
////
//// ## Affected rows
////
//// `pool.exec` counts the rows an `UPDATE` matched, not only those it
//// changed (the `CLIENT_FOUND_ROWS` flag), as Postgres does. Use `insert_id`
//// for the `AUTO_INCREMENT` id an `INSERT` generated.
////
//// ## Authentication and TLS
////
//// `caching_sha2_password` (MySQL 8's default) and `mysql_native_password`
//// are supported, including switching between them as the server asks.
//// When the server hasn't cached a `caching_sha2_password` user, the
//// password is sent over TLS, or without TLS encrypted with the server's
//// RSA public key (fetched during the handshake). TLS is off by default;
//// turn it on with `ssl` or `?ssl-mode=` in the URL. `SslVerified` checks the
//// server's certificate against the system's CA store.
////
//// ## Errors
////
//// Server errors become `sql.Error`s by MySQL error number: `1062` is
//// `UniqueViolation` (with the key's name), `1451`/`1452`
//// `ForeignKeyViolation`, `1048`/`1364` `NotNullViolation` and `3819`
//// `CheckViolation`. Others are `QueryFailed` with the error number as the
//// code, e.g. `"1146"` for a missing table.
////
//// ## Prepared statements
////
//// Each connection keeps up to 100 prepared statements by SQL text (see
//// `statement_cache`), so a statement is prepared once per connection and
//// after that only executed. The least recently used ones are closed when
//// the cache is full.
////
//// ## Timeouts
////
//// A statement that runs past the pool's query timeout fails with
//// `sql.QueryTimeout` and its connection is closed. The server notices when
//// it next writes to the connection; a statement that writes nothing until
//// it ends, such as `SLEEP`, runs to its end on the server.

import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gloss/mysql/internal/connection.{type MyConnection}
import gloss/sql
import gloss/sql/pool
import gloss/url

/// Where and how to connect. Build one with `new` or `from_url` and the
/// setters, then give `driver(config)` to `pool.new`.
pub opaque type Config {
  Config(
    host: String,
    port: Int,
    user: String,
    password: Option(String),
    database: Option(String),
    ssl: Ssl,
    connect_timeout: Duration,
    statement_cache: Int,
    on_connect: List(String),
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

/// `root@localhost:3306` with no database selected, without TLS or a
/// password, with a 5 second connect timeout.
pub fn new() -> Config {
  Config(
    host: "localhost",
    port: 3306,
    user: "root",
    password: None,
    database: None,
    ssl: SslDisabled,
    connect_timeout: duration.seconds(5),
    statement_cache: 100,
    on_connect: [],
  )
}

/// Read a connection URL:
/// `mysql://user:password@host:port/database?ssl-mode=REQUIRED`.
///
/// `ssl-mode` (or `sslmode`) may be `DISABLED`, `PREFERRED`, `REQUIRED`,
/// `VERIFY_CA` or `VERIFY_IDENTITY` (`SslVerified`), in any case.
/// `connect_timeout` (seconds) is understood too; other parameters are
/// refused.
pub fn from_url(text: String) -> Result(Config, Nil) {
  use parsed <- result.try(url.parse(text))
  use Nil <- result.try(case url.scheme(parsed) {
    Some("mysql") -> Ok(Nil)
    _ -> Error(Nil)
  })
  let config = new()
  let config = case url.host(parsed) {
    Some("") | None -> config
    Some(host) -> Config(..config, host:)
  }
  let config = case url.port(parsed) {
    Some(port) -> Config(..config, port:)
    None -> config
  }
  let config = case url.username(parsed) {
    Some(user) -> Config(..config, user:)
    None -> config
  }
  let config = case url.password(parsed) {
    Some(password) -> Config(..config, password: Some(password))
    None -> config
  }
  use config <- result.try(case url.path_segments(parsed) {
    [] -> Ok(config)
    [database] -> Ok(Config(..config, database: Some(database)))
    _ -> Error(Nil)
  })
  let query = url.params(parsed)
  list.try_fold(query, config, fn(config, pair) {
    case pair {
      #("ssl-mode", mode) | #("sslmode", mode) | #("ssl_mode", mode) ->
        case string.lowercase(mode) {
          "disabled" | "disable" -> Ok(Config(..config, ssl: SslDisabled))
          "preferred" | "prefer" -> Ok(Config(..config, ssl: SslPreferred))
          "required" | "require" -> Ok(Config(..config, ssl: SslRequired))
          "verify_ca" | "verify_identity" | "verify-ca" | "verify-full" ->
            Ok(Config(..config, ssl: SslVerified))
          _ -> Error(Nil)
        }
      #("connect_timeout", seconds) ->
        int.parse(seconds)
        |> result.map(fn(s) {
          Config(..config, connect_timeout: duration.seconds(s))
        })
      _ -> Error(Nil)
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

/// The database statements run in. Without one, tables must be named as
/// `database.table`.
pub fn database(config: Config, database: String) -> Config {
  Config(..config, database: Some(database))
}

pub fn ssl(config: Config, ssl: Ssl) -> Config {
  Config(..config, ssl:)
}

/// How long opening a connection, including TLS and authentication, may
/// take.
pub fn connect_timeout(config: Config, timeout: Duration) -> Config {
  Config(..config, connect_timeout: timeout)
}

/// How many prepared statements each connection keeps. `0` turns the
/// cache off, so every statement is prepared, run and closed each time,
/// which suits a proxy such as ProxySQL that multiplexes connections.
pub fn statement_cache(config: Config, size: Int) -> Config {
  Config(..config, statement_cache: int.max(size, 0))
}

/// SQL run on every new connection, after the driver sets the time zone,
/// e.g. `"SET SESSION sql_mode = 'STRICT_ALL_TABLES'"`. Don't change
/// `time_zone`: the driver relies on UTC.
pub fn on_connect(config: Config, sql: String) -> Config {
  Config(..config, on_connect: list.append(config.on_connect, [sql]))
}

/// The driver to give to `pool.new`.
pub fn driver(config: Config) -> pool.Driver {
  let settings = settings(config)
  pool.Driver(name: "mysql", placeholder: fn(_) { "?" }, connect: fn() {
    use connection <- result.map(connection.open(
      settings,
      config.statement_cache,
    ))
    pool.Connection(
      run: fn(text, args, timeout) {
        connection.run(connection, text, args, timeout)
        |> result.map(fn(executed) { executed.outcome })
      },
      run_after: Some(fn(before, text, args, timeout) {
        connection.run_after(connection, before, text, args, timeout)
        |> result.map(fn(executed) { executed.outcome })
      }),
      script: fn(text, timeout) { connection.script(connection, text, timeout) },
      alive: fn() { connection.alive(connection) },
      transfer: fn(pid) { connection.transfer(connection, pid) },
      close: fn() { connection.close(connection) },
      raw: coerce(connection),
    )
  })
}

fn settings(config: Config) -> connection.Settings {
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
    init: config.on_connect,
  )
}

/// Run an `INSERT` and return the id MySQL gave its `AUTO_INCREMENT`
/// column (the first one, when it inserted several rows). MySQL has no
/// `RETURNING`, and `LAST_INSERT_ID()` must be read on the same connection,
/// which this does.
///
/// ```gleam
/// sql.query("insert into users (email) values (?)")
/// |> sql.bind(sql.Text(email))
/// |> mysql.insert_id(db, _)
/// ```
pub fn insert_id(
  db: pool.Db,
  statement: sql.Statement(a),
) -> Result(Int, sql.Error) {
  let #(text, args) = sql.render(statement, fn(_) { "?" })
  use connection, timeout <- pool.borrow(db, sql.name(statement, text))
  use connection <- result.try(from_raw(connection))
  connection.run(connection, text, args, timeout)
  |> result.map(fn(executed) { executed.last_insert_id })
}

fn from_raw(connection: pool.Connection) -> Result(MyConnection, sql.Error) {
  ffi_connection(connection.raw)
  |> result.replace_error(sql.QueryFailed(
    code: "",
    message: "not a MySQL connection",
  ))
}

@external(erlang, "gloss@mysql_ffi", "coerce")
fn coerce(value: a) -> Dynamic

@external(erlang, "gloss@mysql_ffi", "mysql_connection")
fn ffi_connection(raw: Dynamic) -> Result(MyConnection, Nil)

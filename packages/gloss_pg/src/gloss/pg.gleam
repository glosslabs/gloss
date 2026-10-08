//// A Postgres driver for `gloss/sql`, speaking the wire protocol directly.
////
//// ```gleam
//// let assert Ok(config) = pg.from_url("postgres://app:secret@db:5432/app")
//// let assert Ok(db) = pool.new(pg.driver(config)) |> pool.start
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
//// ## Prepared statements
////
//// Each connection keeps up to 100 prepared statements by SQL text (see
//// `statement_cache`), so a statement is parsed once per connection and
//// after that only bound and run. The least recently used ones are closed
//// when the cache is full. Statements built with `sql.arg` and `sql.when`
//// produce one SQL text per combination of parts, and each is cached
//// separately.
////
//// ## LISTEN and NOTIFY
////
//// `notify` is a statement, so it can run in a transaction, and Postgres
//// delivers it on commit. Receiving needs a connection of its own:
////
//// ```gleam
//// let assert Ok(listener) = pg.start_listener(config)
//// let jobs = process.new_subject()
//// let assert Ok(Nil) = pg.listen(listener, "jobs", jobs)
//// let assert Ok(Nil) = pool.exec(db, pg.notify("jobs", "42"))
//// let assert Ok(pg.Notification(channel: "jobs", payload: "42", ..)) =
////   process.receive(jobs, 1000)
//// ```
////
//// If the listener's connection drops it reconnects, with backoff, and
//// listens again. Notifications sent while it was disconnected are lost,
//// so treat one as a hint to go and read the table, not as the data.
////
//// ## COPY
////
//// `copy_in` streams rows into `COPY ... FROM STDIN` and `copy_out` reads
//// `COPY ... TO STDOUT`, both on a connection from the pool (or the
//// transaction's). `copy_row` writes a row in COPY's text format.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gloss/pg/internal/connection.{type PgConnection}
import gloss/pg/internal/listener_process
import gloss/sql
import gloss/sql/internal/postgres as codec
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
    database: String,
    ssl: Ssl,
    application_name: String,
    connect_timeout: Duration,
    parameters: List(#(String, String)),
    statement_cache: Int,
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
    statement_cache: 100,
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
pub fn from_url(text: String) -> Result(Config, Nil) {
  use parsed <- result.try(url.parse(text))
  use Nil <- result.try(case url.scheme(parsed) {
    Some("postgres") | Some("postgresql") -> Ok(Nil)
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
    [database] -> Ok(Config(..config, database:))
    _ -> Error(Nil)
  })
  let query = url.params(parsed)
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

/// How many prepared statements each connection keeps. `0` turns the
/// cache off, so every statement is parsed each time it runs, which suits
/// a connection pooler such as PgBouncer in transaction mode.
pub fn statement_cache(config: Config, size: Int) -> Config {
  Config(..config, statement_cache: int.max(size, 0))
}

/// The driver to give to `pool.new`.
pub fn driver(config: Config) -> pool.Driver {
  let settings = settings(config)
  pool.Driver(
    name: "postgres",
    placeholder: fn(n) { "$" <> int.to_string(n) },
    connect: fn() {
      use connection <- result.map(connection.open(
        settings,
        config.statement_cache,
      ))
      pool.Connection(
        run: fn(text, args, timeout) {
          connection.run(connection, text, args, timeout)
        },
        script: fn(text, timeout) {
          connection.script(connection, text, timeout)
        },
        alive: fn() { connection.alive(connection) },
        transfer: fn(pid) { connection.transfer(connection, pid) },
        close: fn() { connection.close(connection) },
        raw: coerce(connection),
      )
    },
  )
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
    parameters: [
      #("application_name", config.application_name),
      ..list.filter(config.parameters, fn(p) { !fixed(p.0) })
    ],
  )
}

/// Parameters the codec depends on.
fn fixed(name: String) -> Bool {
  case string.lowercase(name) {
    "datestyle" | "timezone" | "client_encoding" | "user" | "database" -> True
    _ -> False
  }
}

// --- NOTIFY ------------------------------------------------------------------

/// Send `payload` to every listener on `channel`. Run it with `pool.exec`;
/// in a transaction it is delivered when the transaction commits.
pub fn notify(channel: String, payload: String) -> sql.Statement(Dynamic) {
  sql.query("select pg_notify($1, $2)")
  |> sql.bind(sql.Text(channel))
  |> sql.bind(sql.Text(payload))
  |> sql.label("notify")
}

// --- LISTEN ------------------------------------------------------------------

/// A notification, as delivered to the subjects given to `listen`.
pub type Notification {
  Notification(
    channel: String,
    payload: String,
    /// The process id of the server backend that sent it.
    sender: Int,
  )
}

/// A connection dedicated to receiving notifications.
pub opaque type Listener {
  Listener(subject: Subject(ListenerMessage))
}

/// The listener process's messages, for naming it with `process.new_name`.
pub type ListenerMessage =
  listener_process.Message(Notification)

/// Open a listener's connection and start it, linked to the calling
/// process. Fails if the connection can't be opened.
pub fn start_listener(config: Config) -> Result(Listener, sql.Error) {
  case listener_process.start(settings(config), Notification, None) {
    Ok(started) -> Ok(Listener(started.data))
    Error(actor.InitFailed(reason)) -> Error(sql.ConnectionFailed(reason))
    Error(error) -> Error(sql.ConnectionFailed(string.inspect(error)))
  }
}

/// A listener for a supervision tree, registered under `name`; reach it
/// with `listener_from_name`. Subscriptions don't survive a restart: listen
/// again after one.
pub fn supervised_listener(
  config: Config,
  name: Name(ListenerMessage),
) -> ChildSpecification(Listener) {
  supervision.worker(fn() {
    listener_process.start(settings(config), Notification, Some(name))
    |> result.map(fn(started) {
      actor.Started(..started, data: Listener(started.data))
    })
  })
}

pub fn listener_from_name(name: Name(ListenerMessage)) -> Listener {
  Listener(process.named_subject(name))
}

/// Send each notification on `channel` to `subject` until `unlisten`, or
/// until the subject's owner exits. The first subscriber to a channel makes
/// the listener run `LISTEN`; while it is reconnecting the subscription is
/// recorded and takes effect once it is back.
pub fn listen(
  listener: Listener,
  channel: String,
  subject: Subject(Notification),
) -> Result(Nil, sql.Error) {
  process.call(listener.subject, 10_000, listener_process.Listen(
    channel,
    subject,
    _,
  ))
}

/// Stop sending notifications on `channel` to `subject`.
pub fn unlisten(
  listener: Listener,
  channel: String,
  subject: Subject(Notification),
) -> Nil {
  process.send(listener.subject, listener_process.Unlisten(channel, subject))
}

/// Close the listener's connection and stop it.
pub fn stop_listener(listener: Listener) -> Nil {
  process.send(listener.subject, listener_process.Stop)
}

// --- COPY --------------------------------------------------------------------

/// Run `COPY ... FROM STDIN`, sending `chunks` as the data, and return how
/// many rows were copied. Chunks needn't line up with rows.
///
/// ```gleam
/// pg.copy_in(db, "copy items (name, qty) from stdin", [
///   pg.copy_row([sql.Text("bolt"), sql.Int(40)]),
///   pg.copy_row([sql.Text("nut"), sql.Null]),
/// ])
/// ```
pub fn copy_in(
  db: pool.Db,
  sql: String,
  chunks: List(BitArray),
) -> Result(Int, sql.Error) {
  copy_in_with(db, sql, chunks, fn(chunks) {
    case chunks {
      [chunk, ..rest] -> Some(#(chunk, rest))
      [] -> None
    }
  })
}

/// `copy_in` for data too large to hold at once: `next` makes each chunk
/// from `state` as it is needed, and `None` ends the copy.
pub fn copy_in_with(
  db: pool.Db,
  sql: String,
  from state: s,
  next next: fn(s) -> Option(#(BitArray, s)),
) -> Result(Int, sql.Error) {
  use connection, timeout <- pool.borrow(db, "copy_in")
  use connection <- result.try(from_raw(connection))
  connection.copy_in(connection, sql, state, next, timeout)
}

/// Run `COPY ... TO STDOUT`, folding each chunk Postgres sends into `acc`.
/// In the text and CSV formats each chunk is one row, ending in a newline.
pub fn copy_out(
  db: pool.Db,
  sql: String,
  from acc: a,
  with fold: fn(a, BitArray) -> a,
) -> Result(a, sql.Error) {
  use connection, timeout <- pool.borrow(db, "copy_out")
  use connection <- result.try(from_raw(connection))
  connection.copy_out(connection, sql, acc, fold, timeout)
}

/// One row in COPY's text format: values separated by tabs, `\N` for
/// NULL, ending in a newline.
pub fn copy_row(values: List(sql.Value)) -> BitArray {
  let fields =
    list.map(values, fn(value) {
      case value {
        sql.Null -> "\\N"
        _ ->
          codec.to_text(value)
          |> string.replace("\\", "\\\\")
          |> string.replace("\n", "\\n")
          |> string.replace("\r", "\\r")
          |> string.replace("\t", "\\t")
      }
    })
  <<string.join(fields, "\t"):utf8, "\n":utf8>>
}

fn from_raw(connection: pool.Connection) -> Result(PgConnection, sql.Error) {
  ffi_connection(connection.raw)
  |> result.replace_error(sql.QueryFailed(
    code: "",
    message: "not a Postgres connection",
  ))
}

@external(erlang, "gloss@pg_ffi", "coerce")
fn coerce(value: a) -> Dynamic

@external(erlang, "gloss@pg_ffi", "pg_connection")
fn ffi_connection(raw: Dynamic) -> Result(PgConnection, Nil)

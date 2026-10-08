//// A Redis client: pooled, pipelined connections, typed helpers for the
//// common commands, transactions, pub/sub, and a span per command.
////
//// ```gleam
//// let assert Ok(config) = redis.from_url("redis://:secret@localhost:6379/0")
//// let assert Ok(r) = config |> redis.tracer(tracer) |> redis.start
////
//// let assert Ok(Nil) = redis.set(r, "greeting", "hello")
//// let assert Ok(Some("hello")) = redis.get(r, "greeting")
//// let assert Ok(3) = redis.incr_by(r, "visits", 3)
//// redis.command(r, ["ZADD", "scores", "10", "ada"])
//// ```
////
//// ## Connections
////
//// `start` opens `pool_size` connections (2 by default). Each is a process
//// that writes requests as they come and matches replies in order, so
//// callers never wait for a free connection: commands from many processes
//// are pipelined on the same few sockets, and one connection usually keeps
//// up with a busy node. Each call waits up to `timeout` (5 seconds by
//// default) for its reply.
////
//// A connection that drops reconnects with backoff, from 100 milliseconds
//// up to 5 seconds. Commands in flight when it drops fail with
//// `ConnectionLost`, and commands while it is down fail at once with
//// `ConnectionFailed`, rather than waiting. `start` succeeds even if Redis
//// is down, so an application can boot without it.
////
//// ## Values
////
//// The typed helpers take and return `String`s. A value that isn't UTF-8
//// comes back as `UnexpectedReply(Bulk(bytes))`; use `command_bits` for
//// binary data, whose replies are `Bulk(BitArray)`.
////
//// ## Tracing
////
//// Each command is a `gloss.redis` span named after the command in lower
//// case (`"get"`), with the `command` and, for commands that take one, its
//// `key` (never values) in its meta. A pipeline or transaction is one span.
//// Spans are children of the caller's current span, so commands made while
//// handling a request appear in its trace.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gloss/internal/runtime
import gloss/meta
import gloss/redis/internal/connection
import gloss/redis/internal/resp
import gloss/tracer.{type Tracer}
import gloss/url

// --- Configuration ------------------------------------------------------------

/// How to reach Redis. Build one with `new` or `from_url` and the setters.
pub opaque type Config {
  Config(
    host: String,
    port: Int,
    tls: Bool,
    verify: Bool,
    username: Option(String),
    password: Option(String),
    database: Int,
    pool_size: Int,
    timeout: Duration,
    tracer: Tracer,
    name: Option(Name(Message)),
  )
}

/// `localhost:6379`, database 0, no password, 2 connections, a 5 second
/// timeout.
pub fn new() -> Config {
  Config(
    host: "localhost",
    port: 6379,
    tls: False,
    verify: True,
    username: None,
    password: None,
    database: 0,
    pool_size: 2,
    timeout: duration.seconds(5),
    tracer: tracer.new(),
    name: None,
  )
}

/// A config from a URL: `redis://[[user]:password@]host[:port][/database]`,
/// or `rediss://` for TLS.
pub fn from_url(text: String) -> Result(Config, Nil) {
  use parsed <- result.try(url.parse(text))
  use tls <- result.try(case url.scheme(parsed) {
    Some("redis") -> Ok(False)
    Some("rediss") -> Ok(True)
    _ -> Error(Nil)
  })
  use host <- result.try(option.to_result(url.host(parsed), Nil))
  // `redis://secret@host` names a password, not a user.
  let #(username, password) = case url.username(parsed), url.password(parsed) {
    Some(user), None -> #(None, Some(user))
    username, password -> #(username, password)
  }
  use database <- result.try(case url.path_segments(parsed) {
    [] -> Ok(0)
    [n] -> int.parse(n)
    _ -> Error(Nil)
  })
  Ok(
    Config(
      ..new(),
      host:,
      port: option.unwrap(url.port(parsed), 6379),
      tls:,
      username:,
      password:,
      database:,
    ),
  )
}

pub fn host(config: Config, host: String) -> Config {
  Config(..config, host:)
}

pub fn port(config: Config, port: Int) -> Config {
  Config(..config, port:)
}

/// Connect over TLS. The server's certificate must chain to a system CA
/// and match the host.
pub fn tls(config: Config, tls: Bool) -> Config {
  Config(..config, tls:)
}

/// The password to `AUTH` with, if any.
pub fn password(config: Config, password: Option(String)) -> Config {
  Config(..config, password:)
}

/// The ACL user to `AUTH` as, with the password. `None` is the default
/// user.
pub fn username(config: Config, username: Option(String)) -> Config {
  Config(..config, username:)
}

/// The database to `SELECT`.
pub fn database(config: Config, database: Int) -> Config {
  Config(..config, database:)
}

/// How many connections to share commands between.
pub fn pool_size(config: Config, size: Int) -> Config {
  Config(..config, pool_size: int.max(size, 1))
}

/// How long a call waits for its reply, and for connecting.
pub fn timeout(config: Config, timeout: Duration) -> Config {
  Config(..config, timeout:)
}

pub fn tracer(config: Config, tracer: Tracer) -> Config {
  Config(..config, tracer:)
}

/// Register the client under `name`, so `from_name` reaches it across
/// restarts.
pub fn named(config: Config, name: Name(Message)) -> Config {
  Config(..config, name: Some(name))
}

// --- Starting -----------------------------------------------------------------

/// Messages the client's owning process understands. Opaque to
/// applications; it is exposed so a `process.Name(Message)` can be made for
/// `named`.
pub opaque type Message {
  Shutdown
}

/// A handle on a running client. Every operation goes straight to a
/// connection; nothing passes through a central process.
pub opaque type Redis {
  Direct(Pool)
  ByName(Name(Message))
}

type Pool {
  Pool(
    owner: Option(Subject(Message)),
    subjects: List(Subject(connection.Message)),
    connections: Connections,
    size: Int,
    counter: Counter,
    tracer: Tracer,
    timeout: Int,
    settings: connection.Settings,
  )
}

type Connections

type Counter

pub type StartError {
  /// The client's processes could not start.
  StartFailed(reason: String)
}

/// Start the client, linked to the caller.
pub fn start(config: Config) -> Result(Redis, StartError) {
  start_owner(config)
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(error) { StartFailed(string.inspect(error)) })
}

/// A child for a supervision tree.
pub fn supervised(config: Config) -> ChildSpecification(Redis) {
  supervision.worker(fn() { start_owner(config) })
}

/// A handle for a client configured with `named`. Usable before the client
/// starts; calls fail with `Unavailable` while it is not running.
pub fn from_name(name: Name(Message)) -> Redis {
  ByName(name)
}

/// Close every connection and stop the client.
pub fn shutdown(redis: Redis) -> Nil {
  case resolve(redis) {
    Ok(Pool(owner: Some(owner), ..)) -> {
      let _ = runtime.try_send(owner, Shutdown)
      Nil
    }
    Ok(pool) -> list.each(pool.subjects, connection.stop)
    Error(_) -> Nil
  }
}

fn start_owner(
  config: Config,
) -> Result(actor.Started(Redis), actor.StartError) {
  let timeout = duration.to_milliseconds(config.timeout)
  let settings = settings(config, reconnect: True)
  let builder =
    actor.new_with_initialiser(timeout * 2 + 1000, fn(self) {
      let started =
        list.repeat(Nil, config.pool_size)
        |> list.try_map(fn(_) { connection.start(settings) })
      case started {
        Error(reason) -> Error(reason)
        Ok(subjects) -> {
          let pool =
            Pool(
              owner: Some(self),
              subjects:,
              connections: tuple_from_list(subjects),
              size: config.pool_size,
              counter: counter_new(),
              tracer: config.tracer,
              timeout:,
              settings:,
            )
          let handle = case config.name {
            Some(name) -> {
              pool_put(name, pool)
              ByName(name)
            }
            None -> Direct(pool)
          }
          Ok(
            subjects
            |> actor.initialised
            |> actor.returning(handle),
          )
        }
      }
    })
    |> actor.on_message(fn(subjects, message) {
      case message {
        Shutdown -> {
          list.each(subjects, connection.stop)
          actor.stop()
        }
      }
    })
  case config.name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
  |> actor.start
}

fn settings(config: Config, reconnect reconnect: Bool) -> connection.Settings {
  connection.Settings(
    host: config.host,
    port: config.port,
    tls: config.tls,
    verify: config.verify,
    username: config.username,
    password: config.password,
    database: config.database,
    connect_timeout: duration.to_milliseconds(config.timeout),
    reconnect:,
    on_connect: [],
    push: None,
  )
}

fn resolve(redis: Redis) -> Result(Pool, Error) {
  case redis {
    Direct(pool) -> Ok(pool)
    ByName(name) -> pool_get(name) |> result.replace_error(Unavailable)
  }
}

// --- Replies and errors -------------------------------------------------------

/// A reply from Redis.
pub type Reply {
  /// A simple string, such as `OK`.
  Status(String)
  Integer(Int)
  Bulk(BitArray)
  Array(List(Reply))
  /// A missing value: a nil bulk string or array.
  Null
  /// An error inside an array, such as one command of a transaction.
  Failed(kind: String, message: String)
}

pub type Error {
  /// No connection could be made, or it hasn't come back yet.
  ConnectionFailed(reason: String)
  /// The connection dropped with the command in flight. It may or may not
  /// have run.
  ConnectionLost(reason: String)
  /// No reply within the timeout. The command may still run.
  Timeout
  /// Redis refused the command. `kind` is the error's first word, such as
  /// `ERR`, `WRONGTYPE` or `NOAUTH`.
  ServerError(kind: String, message: String)
  /// The client isn't running.
  Unavailable
  /// A typed helper got a reply it can't read.
  UnexpectedReply(Reply)
}

/// A one-line description of an error, for logs.
pub fn describe(error: Error) -> String {
  case error {
    ConnectionFailed(reason) -> "connection failed: " <> reason
    ConnectionLost(reason) -> "connection lost: " <> reason
    Timeout -> "timed out waiting for a reply"
    ServerError(kind:, message:) -> kind <> " " <> message
    Unavailable -> "the client is not running"
    UnexpectedReply(reply) -> "unexpected reply: " <> string.inspect(reply)
  }
}

fn reply(value: resp.Value) -> Reply {
  case value {
    resp.Simple(s) -> Status(s)
    resp.Integer(n) -> Integer(n)
    resp.Bulk(b) -> Bulk(b)
    resp.Array(values) -> Array(list.map(values, reply))
    resp.Null -> Null
    resp.Failure(message) -> {
      let #(kind, message) = split_error(message)
      Failed(kind:, message:)
    }
  }
}

/// A top-level error reply becomes an `Error`.
fn result(value: resp.Value) -> Result(Reply, Error) {
  case reply(value) {
    Failed(kind:, message:) -> Error(ServerError(kind:, message:))
    other -> Ok(other)
  }
}

fn split_error(message: String) -> #(String, String) {
  case string.split_once(message, " ") {
    Ok(#(kind, rest)) -> #(kind, rest)
    Error(Nil) -> #(message, "")
  }
}

fn from_failure(failure: connection.Failure) -> Error {
  case failure {
    connection.Lost(reason) -> ConnectionLost(reason)
    connection.Down(reason) -> ConnectionFailed(reason)
    connection.TimedOut -> Timeout
    connection.Gone -> Unavailable
  }
}

// --- Commands -----------------------------------------------------------------

/// Run any command: `redis.command(r, ["ZADD", "scores", "10", "ada"])`.
pub fn command(redis: Redis, arguments: List(String)) -> Result(Reply, Error) {
  command_bits(redis, list.map(arguments, bit_array.from_string))
}

/// Run any command with binary arguments.
pub fn command_bits(
  redis: Redis,
  arguments: List(BitArray),
) -> Result(Reply, Error) {
  use pool <- result.try(resolve(redis))
  use <- traced(pool, span_name(arguments), fn() { command_meta(arguments) })
  use values <- result.try(send(pool, [arguments]))
  case values {
    [value] -> result(value)
    _ -> Error(UnexpectedReply(Array(list.map(values, reply))))
  }
}

/// Run several commands in one round trip. Each has its own result; the
/// outer `Error` is for the connection failing. Commands from other callers
/// may run between them; use `transaction` to run them together.
pub fn pipeline(
  redis: Redis,
  commands: List(List(String)),
) -> Result(List(Result(Reply, Error)), Error) {
  use pool <- result.try(resolve(redis))
  let commands = list.map(commands, list.map(_, bit_array.from_string))
  use <- traced(pool, "pipeline", fn() { batch_meta(commands) })
  use values <- result.try(send(pool, commands))
  Ok(list.map(values, result))
}

/// Run commands atomically with `MULTI` and `EXEC`: no other client's
/// commands run between them. Fails with `ServerError("EXECABORT", ..)` if
/// Redis refused one when it was queued; a command that fails while running
/// fails alone, in its own result.
pub fn transaction(
  redis: Redis,
  commands: List(List(String)),
) -> Result(List(Result(Reply, Error)), Error) {
  use pool <- result.try(resolve(redis))
  use executed <- result.try(exec(pool, commands))
  case executed {
    Some(results) -> Ok(results)
    None -> Error(UnexpectedReply(Null))
  }
}

/// Optimistic locking: `WATCH` `keys` on a connection of its own, call
/// `prepare` with a handle on that connection to read what it needs and
/// return the commands to run, then run them as a `transaction`. `Ok(None)`
/// when a watched key changed before `EXEC`, so nothing ran; try again.
///
/// ```gleam
/// redis.watch(r, ["balance"], fn(tx) {
///   use balance <- result.try(redis.get(tx, "balance"))
///   let balance = option.unwrap(balance, "0") |> int.parse |> result.unwrap(0)
///   Ok([["SET", "balance", int.to_string(balance - 10)]])
/// })
/// ```
pub fn watch(
  redis: Redis,
  keys: List(String),
  prepare: fn(Redis) -> Result(List(List(String)), Error),
) -> Result(Option(List(Result(Reply, Error))), Error) {
  use pool <- result.try(resolve(redis))
  use subject <- result.try(
    connection.start(dedicated(pool.settings))
    |> result.map_error(ConnectionFailed),
  )
  let tx =
    Pool(
      ..pool,
      owner: None,
      subjects: [subject],
      connections: tuple_from_list([subject]),
      size: 1,
      counter: counter_new(),
    )
  let outcome = {
    use _ <- result.try(command(Direct(tx), ["WATCH", ..keys]))
    use commands <- result.try(prepare(Direct(tx)))
    exec(tx, commands)
  }
  connection.stop(subject)
  outcome
}

fn dedicated(settings: connection.Settings) -> connection.Settings {
  connection.Settings(..settings, reconnect: False)
}

fn exec(
  pool: Pool,
  commands: List(List(String)),
) -> Result(Option(List(Result(Reply, Error))), Error) {
  let commands = list.map(commands, list.map(_, bit_array.from_string))
  use <- traced(pool, "transaction", fn() { batch_meta(commands) })
  let all = list.flatten([[[<<"MULTI">>]], commands, [[<<"EXEC">>]]])
  use values <- result.try(send(pool, all))
  case list.last(values) {
    Ok(resp.Array(results)) -> Ok(Some(list.map(results, result)))
    Ok(resp.Null) -> Ok(None)
    Ok(other) -> result(other) |> result.map(fn(r) { Some([Ok(r)]) })
    Error(Nil) -> Error(UnexpectedReply(Null))
  }
}

/// Send commands as one write on the next connection, and wait for all
/// their replies.
fn send(
  pool: Pool,
  commands: List(List(BitArray)),
) -> Result(List(resp.Value), Error) {
  let data = list.map(commands, resp.encode) |> bytes_tree.concat
  let index = counter_next(pool.counter, pool.size)
  connection.call(
    pick(pool.connections, index),
    data,
    list.length(commands),
    pool.timeout,
  )
  |> result.map_error(from_failure)
}

// --- Typed helpers ------------------------------------------------------------

/// The value at `key`, if any.
pub fn get(redis: Redis, key: String) -> Result(Option(String), Error) {
  command(redis, ["GET", key]) |> result.try(optional_text)
}

/// Set `key` to `value`, replacing any value and expiry.
pub fn set(redis: Redis, key: String, value: String) -> Result(Nil, Error) {
  command(redis, ["SET", key, value]) |> result.map(fn(_) { Nil })
}

/// How `set_with` sets a value.
pub type SetOptions {
  SetOptions(
    /// Expire the key after this long.
    expiry: Option(Duration),
    condition: Condition,
  )
}

pub type Condition {
  Always
  /// Only when the key doesn't exist (`NX`).
  IfMissing
  /// Only when the key exists (`XX`).
  IfExists
}

/// No expiry, set always.
pub fn set_options() -> SetOptions {
  SetOptions(expiry: None, condition: Always)
}

/// Set `key` with an expiry or condition. `Ok(False)` when the condition
/// wasn't met, so nothing was set.
///
/// ```gleam
/// redis.set_with(r, "lock", owner, redis.SetOptions(
///   expiry: Some(duration.seconds(30)),
///   condition: redis.IfMissing,
/// ))
/// ```
pub fn set_with(
  redis: Redis,
  key: String,
  value: String,
  options: SetOptions,
) -> Result(Bool, Error) {
  let arguments =
    list.flatten([
      ["SET", key, value],
      case options.expiry {
        Some(expiry) -> ["PX", int.to_string(milliseconds(expiry))]
        None -> []
      },
      case options.condition {
        Always -> []
        IfMissing -> ["NX"]
        IfExists -> ["XX"]
      },
    ])
  use reply <- result.map(command(redis, arguments))
  reply != Null
}

/// Delete keys; the number that existed.
pub fn del(redis: Redis, keys: List(String)) -> Result(Int, Error) {
  command(redis, ["DEL", ..keys]) |> result.try(integer)
}

/// How many of `keys` exist (a key listed twice counts twice).
pub fn exists(redis: Redis, keys: List(String)) -> Result(Int, Error) {
  command(redis, ["EXISTS", ..keys]) |> result.try(integer)
}

/// Expire `key` after `after`. `Ok(False)` when the key doesn't exist.
pub fn expire(
  redis: Redis,
  key: String,
  after: Duration,
) -> Result(Bool, Error) {
  command(redis, ["PEXPIRE", key, int.to_string(milliseconds(after))])
  |> result.try(integer)
  |> result.map(fn(n) { n == 1 })
}

pub type Ttl {
  ExpiresIn(Duration)
  /// The key exists and doesn't expire.
  Persistent
  Missing
}

/// How long `key` has left.
pub fn ttl(redis: Redis, key: String) -> Result(Ttl, Error) {
  use n <- result.map(command(redis, ["PTTL", key]) |> result.try(integer))
  case n {
    -2 -> Missing
    -1 -> Persistent
    ms -> ExpiresIn(duration.milliseconds(ms))
  }
}

/// Add 1 to the integer at `key` (0 if missing); the new value.
pub fn incr(redis: Redis, key: String) -> Result(Int, Error) {
  incr_by(redis, key, 1)
}

/// Add `by` to the integer at `key` (0 if missing); the new value.
pub fn incr_by(redis: Redis, key: String, by: Int) -> Result(Int, Error) {
  command(redis, ["INCRBY", key, int.to_string(by)]) |> result.try(integer)
}

/// The values at `keys`, in order.
pub fn mget(
  redis: Redis,
  keys: List(String),
) -> Result(List(Option(String)), Error) {
  command(redis, ["MGET", ..keys])
  |> result.try(array)
  |> result.try(list.try_map(_, optional_text))
}

/// Set fields of the hash at `key`; the number of fields that were new.
pub fn hset(
  redis: Redis,
  key: String,
  fields: List(#(String, String)),
) -> Result(Int, Error) {
  let pairs = list.flat_map(fields, fn(pair) { [pair.0, pair.1] })
  command(redis, ["HSET", key, ..pairs]) |> result.try(integer)
}

pub fn hget(
  redis: Redis,
  key: String,
  field: String,
) -> Result(Option(String), Error) {
  command(redis, ["HGET", key, field]) |> result.try(optional_text)
}

/// Every field of the hash at `key`; empty if it doesn't exist.
pub fn hgetall(
  redis: Redis,
  key: String,
) -> Result(Dict(String, String), Error) {
  use items <- result.try(
    command(redis, ["HGETALL", key])
    |> result.try(array)
    |> result.try(list.try_map(_, text)),
  )
  pairs(items, dict.new())
}

fn pairs(
  items: List(String),
  acc: Dict(String, String),
) -> Result(Dict(String, String), Error) {
  case items {
    [] -> Ok(acc)
    [field, value, ..rest] -> pairs(rest, dict.insert(acc, field, value))
    [_] -> Error(UnexpectedReply(Null))
  }
}

/// Delete fields of the hash at `key`; the number that existed.
pub fn hdel(
  redis: Redis,
  key: String,
  fields: List(String),
) -> Result(Int, Error) {
  command(redis, ["HDEL", key, ..fields]) |> result.try(integer)
}

/// Push values onto the front of the list at `key`; its new length.
pub fn lpush(
  redis: Redis,
  key: String,
  values: List(String),
) -> Result(Int, Error) {
  command(redis, ["LPUSH", key, ..values]) |> result.try(integer)
}

/// Push values onto the end of the list at `key`; its new length.
pub fn rpush(
  redis: Redis,
  key: String,
  values: List(String),
) -> Result(Int, Error) {
  command(redis, ["RPUSH", key, ..values]) |> result.try(integer)
}

pub fn lpop(redis: Redis, key: String) -> Result(Option(String), Error) {
  command(redis, ["LPOP", key]) |> result.try(optional_text)
}

pub fn rpop(redis: Redis, key: String) -> Result(Option(String), Error) {
  command(redis, ["RPOP", key]) |> result.try(optional_text)
}

/// Elements `start` to `stop` of the list at `key`, inclusive; negative
/// indexes count from the end, so `lrange(r, key, 0, -1)` is all of it.
pub fn lrange(
  redis: Redis,
  key: String,
  start: Int,
  stop: Int,
) -> Result(List(String), Error) {
  command(redis, ["LRANGE", key, int.to_string(start), int.to_string(stop)])
  |> result.try(array)
  |> result.try(list.try_map(_, text))
}

/// Add members to the set at `key`; how many were new.
pub fn sadd(
  redis: Redis,
  key: String,
  members: List(String),
) -> Result(Int, Error) {
  command(redis, ["SADD", key, ..members]) |> result.try(integer)
}

/// Remove members from the set at `key`; how many were there.
pub fn srem(
  redis: Redis,
  key: String,
  members: List(String),
) -> Result(Int, Error) {
  command(redis, ["SREM", key, ..members]) |> result.try(integer)
}

/// The members of the set at `key`, in no particular order.
pub fn smembers(redis: Redis, key: String) -> Result(List(String), Error) {
  command(redis, ["SMEMBERS", key])
  |> result.try(array)
  |> result.try(list.try_map(_, text))
}

/// One step of iterating over keys: start at cursor 0, and continue with
/// the returned cursor until it is 0 again. `pattern` is a glob such as
/// `"session:*"`. A step may return no keys while more remain.
pub fn scan(
  redis: Redis,
  cursor: Int,
  pattern: Option(String),
) -> Result(#(Int, List(String)), Error) {
  let arguments = case pattern {
    Some(pattern) -> ["SCAN", int.to_string(cursor), "MATCH", pattern]
    None -> ["SCAN", int.to_string(cursor)]
  }
  use reply <- result.try(command(redis, arguments))
  case reply {
    Array([Bulk(next), Array(keys)]) -> {
      use next <- result.try(
        bit_array.to_string(next)
        |> result.try(int.parse)
        |> result.replace_error(UnexpectedReply(reply)),
      )
      use keys <- result.map(list.try_map(keys, text))
      #(next, keys)
    }
    _ -> Error(UnexpectedReply(reply))
  }
}

/// Run a Lua script with `EVAL`.
pub fn eval(
  redis: Redis,
  script: String,
  keys: List(String),
  arguments: List(String),
) -> Result(Reply, Error) {
  command(redis, [
    "EVAL",
    script,
    int.to_string(list.length(keys)),
    ..list.append(keys, arguments)
  ])
}

/// Publish `payload` on `channel`; how many subscribers received it.
pub fn publish(
  redis: Redis,
  channel: String,
  payload: String,
) -> Result(Int, Error) {
  command(redis, ["PUBLISH", channel, payload]) |> result.try(integer)
}

fn integer(reply: Reply) -> Result(Int, Error) {
  case reply {
    Integer(n) -> Ok(n)
    _ -> Error(UnexpectedReply(reply))
  }
}

fn array(reply: Reply) -> Result(List(Reply), Error) {
  case reply {
    Array(items) -> Ok(items)
    _ -> Error(UnexpectedReply(reply))
  }
}

fn text(reply: Reply) -> Result(String, Error) {
  case reply {
    Bulk(bytes) ->
      bit_array.to_string(bytes) |> result.replace_error(UnexpectedReply(reply))
    Status(s) -> Ok(s)
    _ -> Error(UnexpectedReply(reply))
  }
}

fn optional_text(reply: Reply) -> Result(Option(String), Error) {
  case reply {
    Null -> Ok(None)
    _ -> text(reply) |> result.map(Some)
  }
}

fn milliseconds(d: Duration) -> Int {
  int.max(duration.to_milliseconds(d), 1)
}

// --- Pub/sub ------------------------------------------------------------------

/// A message published on a channel this process subscribed to.
pub type Published {
  Published(channel: String, payload: BitArray)
}

/// A running subscription, with a connection of its own.
pub opaque type Subscription {
  Subscription(connection: Subject(connection.Message))
}

/// Subscribe to `channels` on a connection of its own, sending each
/// message to `to`. The subscription is linked to the caller. If the
/// connection drops it reconnects and subscribes again; messages published
/// meanwhile are missed, as Redis doesn't keep them.
pub fn subscribe(
  redis: Redis,
  channels: List(String),
  to: Subject(Published),
) -> Result(Subscription, Error) {
  use pool <- result.try(resolve(redis))
  let settings =
    connection.Settings(
      ..pool.settings,
      on_connect: [
        [<<"SUBSCRIBE">>, ..list.map(channels, bit_array.from_string)],
      ],
      push: Some(fn(value) {
        case value {
          resp.Array([
            resp.Bulk(<<"message">>),
            resp.Bulk(channel),
            resp.Bulk(payload),
          ]) ->
            case bit_array.to_string(channel) {
              Ok(channel) -> {
                let _ = runtime.try_send(to, Published(channel:, payload:))
                Nil
              }
              Error(Nil) -> Nil
            }
          // Subscription confirmations and pings.
          _ -> Nil
        }
      }),
    )
  connection.start(settings)
  |> result.map(Subscription)
  |> result.map_error(ConnectionFailed)
}

/// End the subscription and close its connection.
pub fn unsubscribe(subscription: Subscription) -> Nil {
  connection.stop(subscription.connection)
}

// --- Tracing ------------------------------------------------------------------

/// Commands with no key as their first argument.
const keyless = [
  "PING", "ECHO", "AUTH", "SELECT", "INFO", "FLUSHDB", "FLUSHALL", "DBSIZE",
  "MULTI", "EXEC", "DISCARD", "SCAN", "EVAL", "EVALSHA", "SCRIPT", "CLIENT",
  "CONFIG", "HELLO", "TIME", "PUBLISH", "SUBSCRIBE", "WATCH", "UNWATCH", "MGET",
  "MSET", "DEL", "EXISTS",
]

fn span_name(arguments: List(BitArray)) -> String {
  case arguments {
    [name, ..] ->
      bit_array.to_string(name) |> result.unwrap("") |> string.lowercase
    [] -> ""
  }
}

fn command_meta(arguments: List(BitArray)) -> meta.Meta {
  case arguments {
    [name, ..rest] -> {
      let name =
        bit_array.to_string(name) |> result.unwrap("") |> string.uppercase
      let key = case rest, list.contains(keyless, name) {
        [key, ..], False ->
          case bit_array.to_string(key) {
            Ok(key) -> [#("key", meta.String(key))]
            Error(Nil) -> []
          }
        _, _ -> []
      }
      [#("command", meta.String(name)), ..key]
    }
    [] -> []
  }
}

fn batch_meta(commands: List(List(BitArray))) -> meta.Meta {
  let names =
    list.map(commands, fn(arguments) {
      span_name(arguments) |> string.uppercase
    })
  [
    #("commands", meta.Int(list.length(commands))),
    #("command", meta.String(string.join(names, " "))),
  ]
}

/// Run `work` in a span that is a child of the caller's current span.
fn traced(
  pool: Pool,
  name: String,
  meta: fn() -> meta.Meta,
  work: fn() -> Result(a, Error),
) -> Result(a, Error) {
  tracer.span_result(
    pool.tracer,
    source: "gloss.redis",
    name:,
    meta: fn(_) { meta() },
    failure: fn(error) { Some(describe(error)) },
    work:,
  )
}

@external(erlang, "gloss@redis_ffi", "counter_new")
fn counter_new() -> Counter

@external(erlang, "gloss@redis_ffi", "counter_next")
fn counter_next(counter: Counter, size: Int) -> Int

@external(erlang, "gloss@redis_ffi", "pick")
fn pick(connections: Connections, index: Int) -> Subject(connection.Message)

@external(erlang, "gloss@redis_ffi", "tuple_from_list")
fn tuple_from_list(subjects: List(Subject(connection.Message))) -> Connections

@external(erlang, "gloss@redis_ffi", "pool_put")
fn pool_put(name: Name(Message), pool: Pool) -> Nil

@external(erlang, "gloss@redis_ffi", "pool_get")
fn pool_get(name: Name(Message)) -> Result(Pool, Nil)

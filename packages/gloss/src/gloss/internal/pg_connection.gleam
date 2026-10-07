//// One Postgres connection: opening it (TLS, startup, authentication) and
//// running statements over the extended and simple query protocols.

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloss/internal/pg_codec as codec
import gloss/internal/pg_protocol.{type Message} as protocol
import gloss/internal/pg_scram as scram
import gloss/sql

pub type Socket

pub type RecvError {
  Timeout
  Closed
  Failed(String)
}

pub type Tls {
  NoTls
  PreferTls
  RequireTls
  VerifyTls
}

pub type Settings {
  Settings(
    host: String,
    port: Int,
    user: String,
    password: Option(String),
    database: String,
    tls: Tls,
    connect_timeout: Int,
    parameters: List(#(String, String)),
  )
}

/// Read state while talking to the server: bytes received but not yet
/// decoded, and when to give up.
type Reader {
  Reader(socket: Socket, buffer: BitArray, deadline: Int)
}

// --- Opening -----------------------------------------------------------------

pub fn connect(settings: Settings) -> Result(Socket, sql.Error) {
  let deadline = now_ms() + settings.connect_timeout
  use socket <- result.try(
    ffi_connect(settings.host, settings.port, settings.connect_timeout)
    |> result.map_error(sql.ConnectionFailed),
  )
  let opened = {
    use socket <- result.try(negotiate_tls(socket, settings, deadline))
    let parameters = [
      #("user", settings.user),
      #("database", settings.database),
      #("client_encoding", "UTF8"),
      #("DateStyle", "ISO"),
      #("TimeZone", "UTC"),
      ..settings.parameters
    ]
    use Nil <- result.try(send(socket, protocol.startup(parameters)))
    use reader <- result.try(authenticate(
      Reader(socket:, buffer: <<>>, deadline:),
      settings,
    ))
    use _ <- result.map(await_ready(reader))
    socket
  }
  case opened {
    Ok(socket) -> Ok(socket)
    Error(error) -> {
      close_socket(socket)
      Error(as_connection_failure(error))
    }
  }
}

fn negotiate_tls(
  socket: Socket,
  settings: Settings,
  deadline: Int,
) -> Result(Socket, sql.Error) {
  case settings.tls {
    NoTls -> Ok(socket)
    tls -> {
      use Nil <- result.try(send(socket, protocol.ssl_request()))
      case recv(socket, deadline) {
        Ok(<<"S":utf8>>) ->
          ffi_upgrade(
            socket,
            settings.host,
            tls == VerifyTls,
            remaining(deadline),
          )
          |> result.map_error(fn(reason) {
            sql.ConnectionFailed("TLS: " <> reason)
          })
        Ok(<<"N":utf8>>) if tls == PreferTls -> Ok(socket)
        Ok(<<"N":utf8>>) ->
          Error(sql.ConnectionFailed("the server does not support TLS"))
        Ok(_) -> Error(sql.ConnectionFailed("unexpected reply to SSLRequest"))
        Error(error) -> Error(error)
      }
    }
  }
}

fn authenticate(
  reader: Reader,
  settings: Settings,
) -> Result(Reader, sql.Error) {
  use #(message, reader) <- result.try(next(reader))
  case message {
    protocol.Authentication(protocol.AuthenticationOk) -> Ok(reader)

    protocol.Authentication(protocol.CleartextPassword) -> {
      use password <- result.try(password(settings))
      use Nil <- result.try(send(reader.socket, protocol.password(password)))
      authenticate(reader, settings)
    }

    protocol.Authentication(protocol.Md5Password(salt)) -> {
      use password <- result.try(password(settings))
      let inner = md5_hex(<<password:utf8, settings.user:utf8>>)
      let outer = "md5" <> md5_hex(<<inner:utf8, salt:bits>>)
      use Nil <- result.try(send(reader.socket, protocol.password(outer)))
      authenticate(reader, settings)
    }

    protocol.Authentication(protocol.Sasl(mechanisms)) ->
      case list.contains(mechanisms, "SCRAM-SHA-256") {
        False ->
          Error(sql.ConnectionFailed(
            "no supported SASL mechanism in " <> string.join(mechanisms, ", "),
          ))
        True -> {
          use password <- result.try(password(settings))
          scram_exchange(reader, settings, password)
        }
      }

    protocol.Authentication(protocol.UnsupportedAuthentication(code)) ->
      Error(sql.ConnectionFailed(
        "unsupported authentication method " <> int.to_string(code),
      ))

    protocol.ErrorResponse(fields) -> Error(server_error(fields))
    protocol.NoticeResponse(_) -> authenticate(reader, settings)
    _ -> Error(unexpected(message))
  }
}

fn scram_exchange(
  reader: Reader,
  settings: Settings,
  password: String,
) -> Result(Reader, sql.Error) {
  let #(first, client) = scram.client_first("", scram.nonce())
  use Nil <- result.try(send(
    reader.socket,
    protocol.sasl_initial_response("SCRAM-SHA-256", <<first:utf8>>),
  ))
  use #(message, reader) <- result.try(next(reader))
  use server_first <- result.try(case message {
    protocol.Authentication(protocol.SaslContinue(data)) -> utf8(data)
    protocol.ErrorResponse(fields) -> Error(server_error(fields))
    _ -> Error(unexpected(message))
  })
  use #(final, expected) <- result.try(
    scram.client_final(client, password, server_first)
    |> result.replace_error(sql.ConnectionFailed("invalid SCRAM challenge")),
  )
  use Nil <- result.try(send(
    reader.socket,
    protocol.sasl_response(<<final:utf8>>),
  ))
  use #(message, reader) <- result.try(next(reader))
  case message {
    protocol.Authentication(protocol.SaslFinal(data)) -> {
      use server_final <- result.try(utf8(data))
      case scram.verify(server_final, expected) {
        True -> authenticate(reader, settings)
        False ->
          Error(sql.ConnectionFailed("the server's SCRAM signature is wrong"))
      }
    }
    protocol.ErrorResponse(fields) -> Error(server_error(fields))
    _ -> Error(unexpected(message))
  }
}

fn password(settings: Settings) -> Result(String, sql.Error) {
  option.to_result(
    settings.password,
    sql.ConnectionFailed("the server asked for a password and none is set"),
  )
}

fn md5_hex(data: BitArray) -> String {
  crypto.hash(crypto.Md5, data) |> bit_array.base16_encode |> string.lowercase
}

/// Skip parameter statuses and the backend key until the server is ready.
fn await_ready(reader: Reader) -> Result(Reader, sql.Error) {
  use #(message, reader) <- result.try(next(reader))
  case message {
    protocol.ReadyForQuery(_) -> Ok(reader)
    protocol.ErrorResponse(fields) -> Error(server_error(fields))
    _ -> await_ready(reader)
  }
}

fn as_connection_failure(error: sql.Error) -> sql.Error {
  case error {
    sql.ConnectionFailed(_) -> error
    sql.QueryTimeout -> sql.ConnectionFailed("timed out")
    _ -> sql.ConnectionFailed(sql.describe(error))
  }
}

// --- Running statements ------------------------------------------------------

/// An open connection and its prepared statement cache, if it has one.
pub type PgConnection {
  PgConnection(socket: Socket, cache: Option(Cache))
}

/// Statements prepared on this connection, by SQL text. An ETS table, so
/// whichever process has borrowed the connection can use it.
pub type Cache

/// Open a connection that keeps up to `cache_size` prepared statements.
pub fn open(
  settings: Settings,
  cache_size: Int,
) -> Result(PgConnection, sql.Error) {
  use socket <- result.map(connect(settings))
  let cache = case cache_size > 0 {
    True -> Some(ffi_cache_new(cache_size))
    False -> None
  }
  PgConnection(socket:, cache:)
}

/// What the server replied to one request, up to `ReadyForQuery`.
type Reply {
  Reply(
    result: Result(sql.Outcome, sql.Error),
    /// Whether a statement was parsed, so it exists on the server.
    parsed: Bool,
    /// Column types, from a row description.
    types: List(Int),
    /// `I`, `T` or `E`: see `protocol.ReadyForQuery`.
    status: String,
  )
}

/// Run one statement with arguments in a single round trip of the extended
/// query protocol.
///
/// With a cache, a statement is parsed once per connection and then only
/// bound and executed. A cached statement the server no longer accepts
/// (dropped by `DEALLOCATE` or `DISCARD`, or whose result type changed
/// with the schema) is parsed again, and run again when that is safe:
/// outside a transaction, where the failed attempt changed nothing.
pub fn run(
  connection: PgConnection,
  sql: String,
  args: List(sql.Value),
  timeout: Int,
) -> Result(sql.Outcome, sql.Error) {
  let PgConnection(socket:, cache:) = connection
  use <- close_when_broken(socket)
  let args = list.map(args, codec.encode)
  case cache {
    None -> {
      let request = [
        protocol.parse("", sql),
        protocol.bind("", args),
        protocol.describe_portal(),
        protocol.execute(),
        protocol.sync(),
      ]
      request_reply(socket, request, [], timeout)
      |> result.try(fn(reply) { reply.result })
    }
    Some(cache) ->
      case ffi_cache_lookup(cache, sql) {
        Error(Nil) -> prepare_and_run(socket, cache, sql, args, timeout)
        Ok(#(name, types)) -> {
          let request =
            list.append(closes(cache), [
              protocol.bind(name, args),
              protocol.execute(),
              protocol.sync(),
            ])
          use reply <- result.try(request_reply(socket, request, types, timeout))
          case reply.result {
            Error(sql.QueryFailed(code:, ..))
              if code == "0A000" || code == "26000"
            -> {
              ffi_cache_delete(cache, sql)
              case reply.status {
                "I" -> prepare_and_run(socket, cache, sql, args, timeout)
                _ -> reply.result
              }
            }
            result -> result
          }
        }
      }
  }
}

fn prepare_and_run(
  socket: Socket,
  cache: Cache,
  sql: String,
  args: List(protocol.Parameter),
  timeout: Int,
) -> Result(sql.Outcome, sql.Error) {
  let name = ffi_cache_next_name(cache)
  let request =
    list.append(closes(cache), [
      protocol.parse(name, sql),
      protocol.describe_statement(name),
      protocol.bind(name, args),
      protocol.execute(),
      protocol.sync(),
    ])
  use reply <- result.try(request_reply(socket, request, [], timeout))
  case reply.parsed {
    True -> ffi_cache_put(cache, sql, name, reply.types)
    False -> Nil
  }
  reply.result
}

/// Close messages for evicted statements, sent ahead of the next request.
/// Closing a statement that doesn't exist is not an error.
fn closes(cache: Cache) -> List(BytesTree) {
  list.map(ffi_cache_take_closing(cache), protocol.close_statement)
}

fn request_reply(
  socket: Socket,
  request: List(BytesTree),
  types: List(Int),
  timeout: Int,
) -> Result(Reply, sql.Error) {
  use Nil <- result.try(send(socket, bytes_tree.concat(request)))
  let reader = Reader(socket:, buffer: <<>>, deadline: now_ms() + timeout)
  collect(
    reader,
    Collected(types:, rows: [], affected: 0, error: None, parsed: False),
  )
}

/// After a timeout or a broken read the server may still send replies, so
/// the connection can't be trusted with another statement. Closing it makes
/// every later use fail, including inside a transaction, where the pool
/// can't take it back yet.
fn close_when_broken(
  socket: Socket,
  work: fn() -> Result(a, sql.Error),
) -> Result(a, sql.Error) {
  let result = work()
  case result {
    Error(sql.QueryTimeout) | Error(sql.ConnectionLost(_)) -> ffi_close(socket)
    _ -> Nil
  }
  result
}

type Collected {
  Collected(
    types: List(Int),
    rows: List(List(sql.Value)),
    affected: Int,
    error: Option(sql.Error),
    parsed: Bool,
  )
}

/// Read replies up to `ReadyForQuery`. After an error the server skips to
/// `ReadyForQuery`, which is still read so the connection stays usable.
fn collect(reader: Reader, acc: Collected) -> Result(Reply, sql.Error) {
  use #(message, reader) <- result.try(next(reader))
  case message {
    protocol.ParseComplete -> collect(reader, Collected(..acc, parsed: True))
    protocol.RowDescription(columns) ->
      collect(
        reader,
        Collected(..acc, types: list.map(columns, fn(c) { c.type_oid })),
      )
    protocol.DataRow(values) -> {
      let row = list.map2(acc.types, values, decode_value)
      collect(reader, Collected(..acc, rows: [row, ..acc.rows]))
    }
    protocol.CommandComplete(tag) ->
      collect(reader, Collected(..acc, affected: affected_rows(tag)))
    protocol.ErrorResponse(fields) ->
      collect(reader, Collected(..acc, error: Some(server_error(fields))))
    protocol.CopyInResponse -> {
      use Nil <- result.try(send(
        reader.socket,
        protocol.copy_fail("use pg.copy_in for COPY FROM STDIN"),
      ))
      collect(reader, acc)
    }
    protocol.ReadyForQuery(status) -> {
      let result = case acc.error {
        Some(error) -> Error(error)
        None ->
          Ok(sql.Outcome(rows: list.reverse(acc.rows), affected: acc.affected))
      }
      Ok(Reply(result:, parsed: acc.parsed, types: acc.types, status:))
    }
    _ -> collect(reader, acc)
  }
}

fn decode_value(oid: Int, value: Option(BitArray)) -> sql.Value {
  case value {
    Some(raw) -> codec.decode(oid, raw)
    None -> sql.Null
  }
}

/// `INSERT 0 5`, `UPDATE 3`, `SELECT 10`, `COPY 7`, ... -> the count.
/// Commands without one, such as `CREATE TABLE`, count as 0.
fn affected_rows(tag: String) -> Int {
  case string.split(tag, " ") |> list.last {
    Ok(count) -> int.parse(count) |> result.unwrap(0)
    Error(Nil) -> 0
  }
}

/// Run SQL text that may hold several statements using the simple query
/// protocol.
pub fn script(
  connection: PgConnection,
  sql: String,
  timeout: Int,
) -> Result(Nil, sql.Error) {
  let socket = connection.socket
  use <- close_when_broken(socket)
  use reply <- result.try(request_reply(
    socket,
    [protocol.query(sql)],
    [],
    timeout,
  ))
  reply.result |> result.replace(Nil)
}

// --- COPY --------------------------------------------------------------------

/// Run a `COPY ... FROM STDIN` statement, sending the chunks `next` makes
/// until it returns `None`. Returns the number of rows copied. `timeout`
/// applies to waiting for each reply, not to the whole copy.
pub fn copy_in(
  connection: PgConnection,
  sql: String,
  state: s,
  next: fn(s) -> Option(#(BitArray, s)),
  timeout: Int,
) -> Result(Int, sql.Error) {
  let socket = connection.socket
  use <- close_when_broken(socket)
  use Nil <- result.try(send(socket, protocol.query(sql)))
  let reader = Reader(socket:, buffer: <<>>, deadline: now_ms() + timeout)
  await_copy_in(reader, state, next, timeout)
}

fn await_copy_in(
  reader: Reader,
  state: s,
  next: fn(s) -> Option(#(BitArray, s)),
  timeout: Int,
) -> Result(Int, sql.Error) {
  use #(message, reader) <- result.try(next_message(reader))
  case message {
    protocol.CopyInResponse -> {
      use Nil <- result.try(stream_copy_data(reader.socket, state, next))
      let reader = Reader(..reader, deadline: now_ms() + timeout)
      finish(reader)
    }
    // Not a COPY FROM STDIN: read its replies like any statement's.
    protocol.ReadyForQuery(_) -> Ok(0)
    protocol.ErrorResponse(fields) -> {
      use _ <- result.try(finish(reader))
      Error(server_error(fields))
    }
    _ -> await_copy_in(reader, state, next, timeout)
  }
}

fn stream_copy_data(
  socket: Socket,
  state: s,
  next: fn(s) -> Option(#(BitArray, s)),
) -> Result(Nil, sql.Error) {
  case next(state) {
    None -> send(socket, protocol.copy_done())
    Some(#(chunk, state)) -> {
      use Nil <- result.try(send(socket, protocol.copy_data(chunk)))
      stream_copy_data(socket, state, next)
    }
  }
}

/// Read to `ReadyForQuery`, returning the row count from the command tag.
fn finish(reader: Reader) -> Result(Int, sql.Error) {
  use reply <- result.try(collect(
    reader,
    Collected(types: [], rows: [], affected: 0, error: None, parsed: False),
  ))
  reply.result |> result.map(fn(outcome) { outcome.affected })
}

/// Run a `COPY ... TO STDOUT` statement, folding each chunk the server sends
/// (a row, in the text and CSV formats) into `acc`. `timeout` applies to
/// waiting for each chunk, not to the whole copy.
pub fn copy_out(
  connection: PgConnection,
  sql: String,
  acc: a,
  fold: fn(a, BitArray) -> a,
  timeout: Int,
) -> Result(a, sql.Error) {
  let socket = connection.socket
  use <- close_when_broken(socket)
  use Nil <- result.try(send(socket, protocol.query(sql)))
  let reader = Reader(socket:, buffer: <<>>, deadline: now_ms() + timeout)
  read_copy_out(reader, acc, fold, None, timeout)
}

fn read_copy_out(
  reader: Reader,
  acc: a,
  fold: fn(a, BitArray) -> a,
  error: Option(sql.Error),
  timeout: Int,
) -> Result(a, sql.Error) {
  use #(message, reader) <- result.try(next_message(reader))
  let reader = Reader(..reader, deadline: now_ms() + timeout)
  case message {
    protocol.CopyData(data) ->
      read_copy_out(reader, fold(acc, data), fold, error, timeout)
    protocol.ErrorResponse(fields) ->
      read_copy_out(reader, acc, fold, Some(server_error(fields)), timeout)
    protocol.CopyInResponse -> {
      use Nil <- result.try(send(
        reader.socket,
        protocol.copy_fail("use pg.copy_in for COPY FROM STDIN"),
      ))
      read_copy_out(reader, acc, fold, error, timeout)
    }
    protocol.ReadyForQuery(_) ->
      case error {
        Some(error) -> Error(error)
        None -> Ok(acc)
      }
    _ -> read_copy_out(reader, acc, fold, error, timeout)
  }
}

// --- Lifecycle ---------------------------------------------------------------

pub fn alive(connection: PgConnection) -> Bool {
  ffi_alive(connection.socket)
}

/// Make `pid` the owner of the socket and the cache.
pub fn transfer(connection: PgConnection, pid: Pid) -> Nil {
  ffi_transfer(connection.socket, pid)
  case connection.cache {
    Some(cache) -> ffi_cache_give(cache, pid)
    None -> Nil
  }
}

pub fn close(connection: PgConnection) -> Nil {
  close_socket(connection.socket)
  case connection.cache {
    Some(cache) -> ffi_cache_drop(cache)
    None -> Nil
  }
}

pub fn close_socket(socket: Socket) -> Nil {
  let _ = ffi_send(socket, protocol.terminate())
  ffi_close(socket)
}

// --- A socket in active mode, for a listener ---------------------------------

/// What a message to the socket's owner means.
pub type SocketMessage {
  Data(BitArray)
  SocketClosed
  NotSocket
}

/// Deliver the next bytes received as a message to the owner.
pub fn activate(socket: Socket) -> Nil {
  ffi_activate(socket)
}

/// Stop delivering messages, returning bytes delivered but not yet handled.
pub fn deactivate(socket: Socket) -> BitArray {
  ffi_deactivate(socket)
}

pub fn socket_message(socket: Socket, message: Dynamic) -> SocketMessage {
  case ffi_socket_message(socket, message) {
    RawData(data) -> Data(data)
    RawClosed -> SocketClosed
    RawOther -> NotSocket
  }
}

/// Split complete messages off `buffer`, returning them and the rest.
pub fn decode_all(
  buffer: BitArray,
  acc: List(Message),
) -> Result(#(List(Message), BitArray), sql.Error) {
  case protocol.decode(buffer) {
    Ok(#(message, rest)) -> decode_all(rest, [message, ..acc])
    Error(protocol.Incomplete) -> Ok(#(list.reverse(acc), buffer))
    Error(protocol.Malformed) ->
      Error(sql.ConnectionLost("malformed message from the server"))
  }
}

/// Run SQL text in passive mode, starting from bytes already received.
/// Messages other than the replies to it, such as notifications, are given
/// to `other`. Returns the bytes received after `ReadyForQuery`.
pub fn command(
  socket: Socket,
  buffer: BitArray,
  sql: String,
  timeout: Int,
  other: fn(Message) -> Nil,
) -> Result(BitArray, sql.Error) {
  use Nil <- result.try(send(socket, protocol.query(sql)))
  let reader = Reader(socket:, buffer:, deadline: now_ms() + timeout)
  await_command(reader, None, other)
}

fn await_command(
  reader: Reader,
  error: Option(sql.Error),
  other: fn(Message) -> Nil,
) -> Result(BitArray, sql.Error) {
  use #(message, reader) <- result.try(next_message(reader))
  case message {
    protocol.ReadyForQuery(_) ->
      case error {
        Some(error) -> Error(error)
        None -> Ok(reader.buffer)
      }
    protocol.ErrorResponse(fields) ->
      await_command(reader, Some(server_error(fields)), other)
    protocol.NotificationResponse(..) | protocol.NoticeResponse(_) -> {
      other(message)
      await_command(reader, error, other)
    }
    _ -> await_command(reader, error, other)
  }
}

// --- Reading and writing -----------------------------------------------------

fn send(socket: Socket, data: BytesTree) -> Result(Nil, sql.Error) {
  ffi_send(socket, data) |> result.map_error(sql.ConnectionLost)
}

fn next(reader: Reader) -> Result(#(Message, Reader), sql.Error) {
  next_message(reader)
}

fn next_message(reader: Reader) -> Result(#(Message, Reader), sql.Error) {
  case protocol.decode(reader.buffer) {
    Ok(#(message, rest)) -> Ok(#(message, Reader(..reader, buffer: rest)))
    Error(protocol.Malformed) ->
      Error(sql.ConnectionLost("malformed message from the server"))
    Error(protocol.Incomplete) -> {
      use data <- result.try(recv(reader.socket, reader.deadline))
      next_message(Reader(..reader, buffer: <<reader.buffer:bits, data:bits>>))
    }
  }
}

fn recv(socket: Socket, deadline: Int) -> Result(BitArray, sql.Error) {
  case remaining(deadline) {
    0 -> Error(sql.QueryTimeout)
    timeout ->
      case ffi_recv(socket, timeout) {
        Ok(data) -> Ok(data)
        Error(Timeout) -> Error(sql.QueryTimeout)
        Error(Closed) -> Error(sql.ConnectionLost("closed by the server"))
        Error(Failed(reason)) -> Error(sql.ConnectionLost(reason))
      }
  }
}

fn remaining(deadline: Int) -> Int {
  int.max(deadline - now_ms(), 0)
}

fn utf8(data: BitArray) -> Result(String, sql.Error) {
  bit_array.to_string(data)
  |> result.replace_error(sql.ConnectionFailed("invalid UTF-8 from the server"))
}

fn unexpected(message: Message) -> sql.Error {
  sql.ConnectionFailed("unexpected message: " <> string.inspect(message))
}

/// Map an ErrorResponse onto `sql.Error`, by SQLSTATE.
pub fn server_error(fields: List(#(String, String))) -> sql.Error {
  let field = fn(code) { list.key_find(fields, code) |> result.unwrap("") }
  let message = field("M")
  case field("C"), field("V") {
    "23505", _ -> sql.UniqueViolation(constraint: field("n"), message:)
    "23503", _ -> sql.ForeignKeyViolation(constraint: field("n"), message:)
    "23502", _ -> sql.NotNullViolation(column: field("c"), message:)
    "23514", _ -> sql.CheckViolation(constraint: field("n"), message:)
    // Authentication failures and the like end the connection.
    "28" <> _, _ | "08" <> _, _ -> sql.ConnectionFailed(message)
    _, "FATAL" | _, "PANIC" -> sql.ConnectionLost(message)
    code, _ -> sql.QueryFailed(code:, message:)
  }
}

fn now_ms() -> Int {
  monotonic_time(atom.create("millisecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

@external(erlang, "gloss@pg_ffi", "connect")
fn ffi_connect(host: String, port: Int, timeout: Int) -> Result(Socket, String)

@external(erlang, "gloss@pg_ffi", "upgrade")
fn ffi_upgrade(
  socket: Socket,
  host: String,
  verify: Bool,
  timeout: Int,
) -> Result(Socket, String)

@external(erlang, "gloss@pg_ffi", "send")
fn ffi_send(socket: Socket, data: BytesTree) -> Result(Nil, String)

@external(erlang, "gloss@pg_ffi", "recv")
fn ffi_recv(socket: Socket, timeout: Int) -> Result(BitArray, RecvError)

@external(erlang, "gloss@pg_ffi", "alive")
fn ffi_alive(socket: Socket) -> Bool

@external(erlang, "gloss@pg_ffi", "transfer")
fn ffi_transfer(socket: Socket, pid: Pid) -> Nil

@external(erlang, "gloss@pg_ffi", "close")
fn ffi_close(socket: Socket) -> Nil

@external(erlang, "gloss@pg_ffi", "activate")
fn ffi_activate(socket: Socket) -> Nil

@external(erlang, "gloss@pg_ffi", "deactivate")
fn ffi_deactivate(socket: Socket) -> BitArray

type RawSocketMessage {
  RawData(BitArray)
  RawClosed
  RawOther
}

@external(erlang, "gloss@pg_ffi", "socket_message")
fn ffi_socket_message(socket: Socket, message: Dynamic) -> RawSocketMessage

@external(erlang, "gloss@pg_ffi", "cache_new")
fn ffi_cache_new(size: Int) -> Cache

@external(erlang, "gloss@pg_ffi", "cache_lookup")
fn ffi_cache_lookup(
  cache: Cache,
  sql: String,
) -> Result(#(String, List(Int)), Nil)

@external(erlang, "gloss@pg_ffi", "cache_next_name")
fn ffi_cache_next_name(cache: Cache) -> String

@external(erlang, "gloss@pg_ffi", "cache_put")
fn ffi_cache_put(
  cache: Cache,
  sql: String,
  name: String,
  types: List(Int),
) -> Nil

@external(erlang, "gloss@pg_ffi", "cache_delete")
fn ffi_cache_delete(cache: Cache, sql: String) -> Nil

@external(erlang, "gloss@pg_ffi", "cache_take_closing")
fn ffi_cache_take_closing(cache: Cache) -> List(String)

@external(erlang, "gloss@pg_ffi", "cache_give")
fn ffi_cache_give(cache: Cache, pid: Pid) -> Nil

@external(erlang, "gloss@pg_ffi", "cache_drop")
fn ffi_cache_drop(cache: Cache) -> Nil

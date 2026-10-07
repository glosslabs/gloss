//// One Postgres connection: opening it (TLS, startup, authentication) and
//// running statements over the extended and simple query protocols.

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/crypto
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
      close(socket)
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
    protocol.ReadyForQuery -> Ok(reader)
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

/// Run one statement with arguments using the extended query protocol, in a
/// single round trip.
pub fn run(
  socket: Socket,
  sql: String,
  args: List(sql.Value),
  timeout: Int,
) -> Result(sql.Outcome, sql.Error) {
  let request =
    bytes_tree.concat([
      protocol.parse(sql),
      protocol.bind(list.map(args, codec.encode)),
      protocol.describe_portal(),
      protocol.execute(),
      protocol.sync(),
    ])
  use <- close_when_broken(socket)
  use Nil <- result.try(send(socket, request))
  let reader = Reader(socket:, buffer: <<>>, deadline: now_ms() + timeout)
  collect(reader, [], [], 0, None)
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

/// Read the replies to one extended query up to `ReadyForQuery`. After an
/// error the server skips to `ReadyForQuery`, which is still read so the
/// connection stays usable.
fn collect(
  reader: Reader,
  types: List(Int),
  rows: List(List(sql.Value)),
  affected: Int,
  error: Option(sql.Error),
) -> Result(sql.Outcome, sql.Error) {
  use #(message, reader) <- result.try(next(reader))
  case message {
    protocol.RowDescription(columns) ->
      collect(
        reader,
        list.map(columns, fn(c) { c.type_oid }),
        rows,
        affected,
        error,
      )
    protocol.DataRow(values) -> {
      let row = list.map2(types, values, decode_value)
      collect(reader, types, [row, ..rows], affected, error)
    }
    protocol.CommandComplete(tag) ->
      collect(reader, types, rows, affected_rows(tag), error)
    protocol.ErrorResponse(fields) ->
      collect(reader, types, rows, affected, Some(server_error(fields)))
    protocol.CopyInResponse -> {
      use Nil <- result.try(send(
        reader.socket,
        protocol.copy_fail("COPY FROM STDIN is not supported"),
      ))
      collect(reader, types, rows, affected, error)
    }
    protocol.ReadyForQuery ->
      case error {
        Some(error) -> Error(error)
        None -> Ok(sql.Outcome(rows: list.reverse(rows), affected:))
      }
    _ -> collect(reader, types, rows, affected, error)
  }
}

fn decode_value(oid: Int, value: Option(BitArray)) -> sql.Value {
  case value {
    Some(raw) -> codec.decode(oid, raw)
    None -> sql.Null
  }
}

/// `INSERT 0 5`, `UPDATE 3`, `SELECT 10`, ... -> the count. Commands without
/// one, such as `CREATE TABLE`, count as 0.
fn affected_rows(tag: String) -> Int {
  case string.split(tag, " ") |> list.last {
    Ok(count) -> int.parse(count) |> result.unwrap(0)
    Error(Nil) -> 0
  }
}

/// Run SQL text that may hold several statements using the simple query
/// protocol.
pub fn script(
  socket: Socket,
  sql: String,
  timeout: Int,
) -> Result(Nil, sql.Error) {
  use <- close_when_broken(socket)
  use Nil <- result.try(send(socket, protocol.query(sql)))
  let reader = Reader(socket:, buffer: <<>>, deadline: now_ms() + timeout)
  collect(reader, [], [], 0, None) |> result.replace(Nil)
}

pub fn alive(socket: Socket) -> Bool {
  ffi_alive(socket)
}

pub fn transfer(socket: Socket, pid: Pid) -> Nil {
  ffi_transfer(socket, pid)
}

pub fn close(socket: Socket) -> Nil {
  let _ = ffi_send(socket, protocol.terminate())
  ffi_close(socket)
}

// --- Reading and writing -----------------------------------------------------

fn send(socket: Socket, data: BytesTree) -> Result(Nil, sql.Error) {
  ffi_send(socket, data) |> result.map_error(sql.ConnectionLost)
}

fn next(reader: Reader) -> Result(#(Message, Reader), sql.Error) {
  case protocol.decode(reader.buffer) {
    Ok(#(message, rest)) -> Ok(#(message, Reader(..reader, buffer: rest)))
    Error(protocol.Malformed) ->
      Error(sql.ConnectionLost("malformed message from the server"))
    Error(protocol.Incomplete) -> {
      use data <- result.try(recv(reader.socket, reader.deadline))
      next(Reader(..reader, buffer: <<reader.buffer:bits, data:bits>>))
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

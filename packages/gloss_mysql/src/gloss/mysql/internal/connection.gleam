//// One MySQL connection: opening it (TLS, handshake, authentication) and
//// running statements over the binary (prepared) and text protocols.

import gleam/bit_array
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloss/internal/runtime
import gloss/internal/socket as tcp
import gloss/internal/statement_cache
import gloss/mysql/internal/auth
import gloss/mysql/internal/codec
import gloss/mysql/internal/protocol.{type Column, type ServerError}
import gloss/sql

pub type Socket =
  tcp.Socket

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
    database: Option(String),
    tls: Tls,
    connect_timeout: Int,
    /// SQL run on every new connection, after the driver's own settings.
    init: List(String),
  )
}

/// Read state while talking to the server: bytes received but not yet
/// decoded, when to give up, and how many replies to statements sent ahead
/// (see `run_after`) come before the next one.
type Reader {
  Reader(socket: Socket, buffer: BitArray, deadline: Int, pending: Int)
}

fn new_reader(socket: Socket, deadline: Int) -> Reader {
  Reader(socket:, buffer: <<>>, deadline:, pending: 0)
}

/// An open connection and its prepared statement cache, if it has one.
pub type MyConnection {
  MyConnection(socket: Socket, cache: Option(Cache), deprecate_eof: Bool)
}

/// Statements prepared on this connection, by SQL text.
pub type Cache =
  statement_cache.Cache(Statement)

/// A statement prepared on the server.
pub type Statement {
  Statement(id: Int, params: Int)
}

// --- Opening -----------------------------------------------------------------

/// Open a connection that keeps up to `cache_size` prepared statements.
pub fn open(
  settings: Settings,
  cache_size: Int,
) -> Result(MyConnection, sql.Error) {
  let deadline = now_ms() + settings.connect_timeout
  use socket <- result.try(
    tcp.connect(settings.host, settings.port, settings.connect_timeout)
    |> result.map_error(sql.ConnectionFailed),
  )
  let opened = {
    use #(socket, deprecate_eof) <- result.try(handshake(
      socket,
      settings,
      deadline,
    ))
    let connection = MyConnection(socket:, cache: None, deprecate_eof:)
    // Timestamps are exchanged in UTC; see gloss/mysql.
    let init = ["SET time_zone = '+00:00'", ..settings.init]
    use Nil <- result.map(
      list.try_each(init, fn(sql) {
        script(connection, sql, remaining(deadline))
      }),
    )
    connection
  }
  case opened {
    Ok(connection) -> {
      let cache = case cache_size > 0 {
        True -> Some(statement_cache.new(cache_size))
        False -> None
      }
      Ok(MyConnection(..connection, cache:))
    }
    Error(error) -> {
      tcp.close(socket)
      Error(as_connection_failure(error))
    }
  }
}

/// Read the greeting, negotiate TLS and authenticate. Returns the socket,
/// which TLS replaces, and whether the server ends column definitions
/// without an EOF packet.
fn handshake(
  socket: Socket,
  settings: Settings,
  deadline: Int,
) -> Result(#(Socket, Bool), sql.Error) {
  let reader = new_reader(socket, deadline)
  use #(sequence, payload, reader) <- result.try(read(reader))
  use greeting <- result.try(case payload {
    <<0xFF, _:bits>> ->
      case protocol.response(payload) {
        Ok(protocol.ErrPacket(error)) ->
          Error(sql.ConnectionFailed(error.message))
        _ -> Error(sql.ConnectionFailed("the server refused the connection"))
      }
    _ ->
      protocol.handshake(payload)
      |> result.replace_error(sql.ConnectionFailed(
        "unsupported handshake from the server",
      ))
  })
  use Nil <- result.try(
    case protocol.has(greeting.capabilities, protocol.client_protocol_41) {
      True -> Ok(Nil)
      False ->
        Error(sql.ConnectionFailed(
          "the server is too old: protocol 4.1 is required",
        ))
    },
  )
  let capabilities = case settings.database {
    Some(_) -> protocol.capabilities() + protocol.client_connect_with_db
    None -> protocol.capabilities()
  }
  // Only ask for what the server offers.
  let capabilities = int.bitwise_and(capabilities, greeting.capabilities)
  let sequence = protocol.next(sequence)
  use #(reader, capabilities, sequence, tls) <- result.try(negotiate_tls(
    reader,
    settings,
    greeting.capabilities,
    capabilities,
    sequence,
  ))
  let plugin = case greeting.plugin {
    "caching_sha2_password" -> "caching_sha2_password"
    _ -> "mysql_native_password"
  }
  let password = option.unwrap(settings.password, "")
  let response =
    protocol.handshake_response(
      capabilities,
      settings.user,
      scramble(plugin, password, greeting.scramble),
      settings.database,
      plugin,
    )
  use Nil <- result.try(send(reader.socket, response, sequence))
  let state =
    Auth(
      plugin:,
      password:,
      scramble: greeting.scramble,
      tls:,
      sequence: protocol.next(sequence),
    )
  use reader <- result.map(authenticate(reader, state))
  #(reader.socket, protocol.has(capabilities, protocol.client_deprecate_eof))
}

fn negotiate_tls(
  reader: Reader,
  settings: Settings,
  server: Int,
  capabilities: Int,
  sequence: Int,
) -> Result(#(Reader, Int, Int, Bool), sql.Error) {
  let offered = protocol.has(server, protocol.client_ssl)
  case settings.tls, offered {
    NoTls, _ | PreferTls, False -> Ok(#(reader, capabilities, sequence, False))
    _, False -> Error(sql.ConnectionFailed("the server does not support TLS"))
    tls, True -> {
      let capabilities = capabilities + protocol.client_ssl
      use Nil <- result.try(send(
        reader.socket,
        protocol.ssl_request(capabilities),
        sequence,
      ))
      use socket <- result.map(
        tcp.upgrade(
          reader.socket,
          settings.host,
          tls == VerifyTls,
          remaining(reader.deadline),
        )
        |> result.map_error(fn(reason) {
          sql.ConnectionFailed("TLS: " <> reason)
        }),
      )
      #(Reader(..reader, socket:), capabilities, protocol.next(sequence), True)
    }
  }
}

type Auth {
  Auth(
    plugin: String,
    password: String,
    scramble: BitArray,
    tls: Bool,
    sequence: Int,
  )
}

fn scramble(plugin: String, password: String, nonce: BitArray) -> BitArray {
  case plugin {
    "caching_sha2_password" -> auth.caching_sha2(password, nonce)
    _ -> auth.native_password(password, nonce)
  }
}

/// Follow the server through authentication: switches to another plugin,
/// caching_sha2_password's extra steps, until OK or an error.
fn authenticate(reader: Reader, state: Auth) -> Result(Reader, sql.Error) {
  use #(sequence, payload, reader) <- result.try(read(reader))
  let state = Auth(..state, sequence: protocol.next(sequence))
  case payload {
    <<0x00, _:bits>> -> Ok(reader)
    <<0xFF, _:bits>> ->
      case protocol.response(payload) {
        Ok(protocol.ErrPacket(error)) ->
          Error(sql.ConnectionFailed(error.message))
        _ -> Error(sql.ConnectionFailed("authentication failed"))
      }
    // Switch to the plugin the user's account uses, with a new nonce.
    <<0xFE, rest:bits>> -> {
      use #(plugin, nonce) <- result.try(
        protocol.nul_terminated(rest)
        |> result.replace_error(sql.ConnectionFailed(
          "the server asked for an unsupported authentication method",
        )),
      )
      let plugin = bit_array.to_string(plugin) |> result.unwrap("")
      let nonce = bit_array.slice(nonce, 0, 20) |> result.unwrap(nonce)
      case plugin {
        "mysql_native_password" | "caching_sha2_password" -> {
          let state = Auth(..state, plugin:, scramble: nonce)
          use Nil <- result.try(send(
            reader.socket,
            scramble(plugin, state.password, nonce),
            state.sequence,
          ))
          authenticate(
            reader,
            Auth(..state, sequence: protocol.next(state.sequence)),
          )
        }
        _ ->
          Error(sql.ConnectionFailed(
            "unsupported authentication plugin " <> plugin,
          ))
      }
    }
    // caching_sha2_password: the server had the password cached.
    <<0x01, 0x03>> -> authenticate(reader, state)
    // caching_sha2_password: it hasn't, so it needs the password itself.
    <<0x01, 0x04>> ->
      case state.tls {
        True -> {
          use Nil <- result.try(send(
            reader.socket,
            <<state.password:utf8, 0>>,
            state.sequence,
          ))
          authenticate(
            reader,
            Auth(..state, sequence: protocol.next(state.sequence)),
          )
        }
        False -> {
          use Nil <- result.try(send(
            reader.socket,
            protocol.request_public_key(),
            state.sequence,
          ))
          use #(sequence, payload, reader) <- result.try(read(reader))
          case payload {
            <<0x01, pem:bits>> -> {
              use encrypted <- result.try(
                ffi_rsa_encrypt(
                  pem,
                  auth.obfuscated(state.password, state.scramble),
                )
                |> result.replace_error(sql.ConnectionFailed(
                  "could not encrypt the password with the server's key",
                )),
              )
              let sequence = protocol.next(sequence)
              use Nil <- result.try(send(reader.socket, encrypted, sequence))
              authenticate(
                reader,
                Auth(..state, sequence: protocol.next(sequence)),
              )
            }
            _ ->
              Error(sql.ConnectionFailed(
                "the server did not send its public key",
              ))
          }
        }
      }
    _ -> Error(sql.ConnectionFailed("unexpected reply during authentication"))
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

/// What a command produced: its outcome, and the id an `AUTO_INCREMENT`
/// column was given.
pub type Executed {
  Executed(outcome: sql.Outcome, last_insert_id: Int)
}

/// Run one statement with arguments through the binary protocol.
///
/// With a cache, a statement is prepared once per connection and after
/// that only executed. A cached statement the server no longer knows is
/// prepared again.
pub fn run(
  connection: MyConnection,
  sql: String,
  args: List(sql.Value),
  timeout: Int,
) -> Result(Executed, sql.Error) {
  run_after(connection, [], sql, args, timeout)
}

/// `run`, after statements without arguments such as `BEGIN`, sent ahead
/// in the same write. The server still runs the statement when one before
/// it fails, so the connection is then closed rather than trusted.
pub fn run_after(
  connection: MyConnection,
  before: List(String),
  sql: String,
  args: List(sql.Value),
  timeout: Int,
) -> Result(Executed, sql.Error) {
  use <- close_when_broken(connection.socket)
  use params <- result.try(
    list.try_map(args, codec.encode)
    |> result.map_error(fn(message) { sql.QueryFailed(code: "", message:) }),
  )
  let deadline = now_ms() + timeout
  use Nil <- result.try(
    list.try_each(before, fn(statement) {
      send(connection.socket, protocol.query(statement), 0)
    }),
  )
  // The first command's reader reads the replies to `before` first.
  let first =
    Reader(
      ..new_reader(connection.socket, deadline),
      pending: list.length(before),
    )
  case connection.cache {
    None -> {
      use statement <- result.try(prepare(connection, sql, first))
      let result =
        execute(
          connection,
          statement,
          params,
          new_reader(connection.socket, deadline),
        )
      // A statement that was never cached is closed at once.
      let _ = send(connection.socket, protocol.close_statement(statement.id), 0)
      result
    }
    Some(cache) -> {
      use Nil <- result.try(close_evicted(connection, cache))
      case statement_cache.lookup(cache, sql) {
        Ok(statement) -> {
          let result = execute(connection, statement, params, first)
          case result {
            // The server forgot the statement or wants it prepared again.
            Error(sql.QueryFailed(code: "1243", ..))
            | Error(sql.QueryFailed(code: "1615", ..)) -> {
              statement_cache.delete(cache, sql)
              use Nil <- result.try(close_evicted(connection, cache))
              prepare_and_execute(
                connection,
                cache,
                sql,
                params,
                new_reader(connection.socket, deadline),
              )
            }
            _ -> result
          }
        }
        Error(Nil) -> prepare_and_execute(connection, cache, sql, params, first)
      }
    }
  }
}

fn prepare_and_execute(
  connection: MyConnection,
  cache: Cache,
  sql: String,
  params: List(protocol.Param),
  reader: Reader,
) -> Result(Executed, sql.Error) {
  use statement <- result.try(prepare(connection, sql, reader))
  statement_cache.put(cache, sql, statement)
  execute(
    connection,
    statement,
    params,
    new_reader(connection.socket, reader.deadline),
  )
}

/// Close statements evicted from the cache. `COM_STMT_CLOSE` has no reply.
fn close_evicted(
  connection: MyConnection,
  cache: Cache,
) -> Result(Nil, sql.Error) {
  statement_cache.take_closing(cache)
  |> list.try_each(fn(statement: Statement) {
    send(connection.socket, protocol.close_statement(statement.id), 0)
  })
}

fn prepare(
  connection: MyConnection,
  sql: String,
  reader: Reader,
) -> Result(Statement, sql.Error) {
  use Nil <- result.try(send(connection.socket, protocol.prepare(sql), 0))
  use #(_, payload, reader) <- result.try(read(reader))
  case payload {
    <<0xFF, _:bits>> -> Error(error_packet(payload))
    _ -> {
      use prepared <- result.try(
        protocol.prepared(payload) |> result.replace_error(malformed()),
      )
      // Parameter and column definitions follow; the driver reads columns
      // from each execution instead.
      let definitions =
        definition_packets(prepared.params, connection.deprecate_eof)
        + definition_packets(prepared.columns, connection.deprecate_eof)
      use _ <- result.map(skip(reader, definitions))
      Statement(id: prepared.id, params: prepared.params)
    }
  }
}

fn definition_packets(count: Int, deprecate_eof: Bool) -> Int {
  case count, deprecate_eof {
    0, _ -> 0
    n, True -> n
    n, False -> n + 1
  }
}

fn skip(reader: Reader, count: Int) -> Result(Reader, sql.Error) {
  case count {
    0 -> Ok(reader)
    _ -> {
      use #(_, _, reader) <- result.try(read(reader))
      skip(reader, count - 1)
    }
  }
}

fn execute(
  connection: MyConnection,
  statement: Statement,
  params: List(protocol.Param),
  reader: Reader,
) -> Result(Executed, sql.Error) {
  case list.length(params) == statement.params {
    False -> {
      // Nothing is sent, but replies to statements sent ahead are due.
      use _ <- result.try(settle(reader))
      Error(sql.QueryFailed(
        code: "",
        message: "the statement has "
          <> int.to_string(statement.params)
          <> " placeholders but was given "
          <> int.to_string(list.length(params))
          <> " arguments",
      ))
    }
    True -> {
      use Nil <- result.try(send(
        connection.socket,
        protocol.execute(statement.id, params),
        0,
      ))
      read_results(reader, connection.deprecate_eof, Binary, empty())
    }
  }
}

/// Run SQL text that may hold several statements through the text
/// protocol, discarding any rows.
pub fn script(
  connection: MyConnection,
  sql: String,
  timeout: Int,
) -> Result(Nil, sql.Error) {
  use <- close_when_broken(connection.socket)
  use Nil <- result.try(send(connection.socket, protocol.query(sql), 0))
  let reader = new_reader(connection.socket, now_ms() + timeout)
  read_results(reader, connection.deprecate_eof, Text, empty())
  |> result.replace(Nil)
}

/// How rows are encoded: the binary protocol's typed values, or the text
/// protocol's, which the driver only skips.
type Rows {
  Binary
  Text
}

type Acc {
  Acc(rows: List(List(sql.Value)), affected: Int, last_insert_id: Int)
}

fn empty() -> Acc {
  Acc(rows: [], affected: 0, last_insert_id: 0)
}

/// Read every result set of a command: OK packets and rows, until one says
/// no more follow, or an error.
fn read_results(
  reader: Reader,
  deprecate_eof: Bool,
  rows: Rows,
  acc: Acc,
) -> Result(Executed, sql.Error) {
  use #(_, payload, reader) <- result.try(read(reader))
  case payload {
    <<0xFF, _:bits>> -> Error(error_packet(payload))
    <<0x00, _:bits>> ->
      case protocol.response(payload) {
        Ok(protocol.OkPacket(affected:, last_insert_id:, status:)) -> {
          let acc = Acc(..acc, affected:, last_insert_id:)
          more(reader, deprecate_eof, rows, acc, status)
        }
        _ -> Error(malformed())
      }
    <<0xFB, _:bits>> ->
      Error(sql.QueryFailed(
        code: "",
        message: "LOAD DATA LOCAL is not supported",
      ))
    _ -> {
      use #(count, _) <- result.try(
        protocol.lenenc_count(payload) |> result.replace_error(malformed()),
      )
      use #(columns, reader) <- result.try(read_columns(reader, count, []))
      use reader <- result.try(case deprecate_eof {
        True -> Ok(reader)
        False -> skip(reader, 1)
      })
      read_rows(reader, deprecate_eof, rows, columns, acc, 0)
    }
  }
}

fn more(
  reader: Reader,
  deprecate_eof: Bool,
  rows: Rows,
  acc: Acc,
  status: Int,
) -> Result(Executed, sql.Error) {
  case protocol.has(status, protocol.server_more_results_exists) {
    True -> read_results(reader, deprecate_eof, rows, acc)
    False ->
      Ok(Executed(
        outcome: sql.Outcome(
          rows: list.reverse(acc.rows),
          affected: acc.affected,
        ),
        last_insert_id: acc.last_insert_id,
      ))
  }
}

fn read_columns(
  reader: Reader,
  count: Int,
  acc: List(Column),
) -> Result(#(List(Column), Reader), sql.Error) {
  case count {
    0 -> Ok(#(list.reverse(acc), reader))
    _ -> {
      use #(_, payload, reader) <- result.try(read(reader))
      use column <- result.try(
        protocol.column(payload) |> result.replace_error(malformed()),
      )
      read_columns(reader, count - 1, [column, ..acc])
    }
  }
}

fn read_rows(
  reader: Reader,
  deprecate_eof: Bool,
  rows: Rows,
  columns: List(Column),
  acc: Acc,
  count: Int,
) -> Result(Executed, sql.Error) {
  use #(_, payload, reader) <- result.try(read(reader))
  case payload {
    <<0xFF, _:bits>> -> Error(error_packet(payload))
    _ ->
      case protocol.is_terminator(payload) {
        True -> {
          let status = case protocol.response(payload) {
            Ok(protocol.OkPacket(status:, ..))
            | Ok(protocol.EofPacket(status:)) -> status
            _ -> 0
          }
          // A query's row count is how many rows it returned.
          more(reader, deprecate_eof, rows, Acc(..acc, affected: count), status)
        }
        False ->
          case rows {
            Text ->
              read_rows(reader, deprecate_eof, rows, columns, acc, count + 1)
            Binary -> {
              use row <- result.try(
                codec.decode_row(columns, payload)
                |> result.replace_error(malformed()),
              )
              let acc = Acc(..acc, rows: [row, ..acc.rows])
              read_rows(reader, deprecate_eof, rows, columns, acc, count + 1)
            }
          }
      }
  }
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
    Error(sql.QueryTimeout) | Error(sql.ConnectionLost(_)) -> tcp.close(socket)
    _ -> Nil
  }
  result
}

// --- Lifecycle ---------------------------------------------------------------

pub fn alive(connection: MyConnection) -> Bool {
  tcp.alive(connection.socket)
}

/// Make `pid` the owner of the socket and the cache.
pub fn transfer(connection: MyConnection, pid: Pid) -> Nil {
  tcp.transfer(connection.socket, pid)
  case connection.cache {
    Some(cache) -> statement_cache.give(cache, pid)
    None -> Nil
  }
}

pub fn close(connection: MyConnection) -> Nil {
  let _ = send(connection.socket, protocol.quit(), 0)
  tcp.close(connection.socket)
  case connection.cache {
    Some(cache) -> statement_cache.drop(cache)
    None -> Nil
  }
}

// --- Reading and writing -----------------------------------------------------

fn send(
  socket: Socket,
  payload: BitArray,
  sequence: Int,
) -> Result(Nil, sql.Error) {
  let #(data, _) = protocol.frame(payload, sequence)
  tcp.send(socket, data) |> result.map_error(sql.ConnectionLost)
}

/// The next logical packet: its last sequence id and its payload, joined
/// up when it spanned several physical packets.
fn read(reader: Reader) -> Result(#(Int, BitArray, Reader), sql.Error) {
  use reader <- result.try(settle(reader))
  read_loop(reader, <<>>)
}

/// Read the replies to statements sent ahead, each an OK packet. When one
/// failed, the connection is closed: the replies after it can't be matched
/// to what the caller expects.
fn settle(reader: Reader) -> Result(Reader, sql.Error) {
  case reader.pending {
    0 -> Ok(reader)
    pending -> {
      use #(_, payload, reader) <- result.try(read_loop(reader, <<>>))
      case payload {
        <<0xFF, _:bits>> -> {
          tcp.close(reader.socket)
          Error(error_packet(payload))
        }
        _ -> settle(Reader(..reader, pending: pending - 1))
      }
    }
  }
}

fn read_loop(
  reader: Reader,
  acc: BitArray,
) -> Result(#(Int, BitArray, Reader), sql.Error) {
  case protocol.take_packet(reader.buffer) {
    Ok(#(sequence, payload, rest)) -> {
      let reader = Reader(..reader, buffer: rest)
      let acc = <<acc:bits, payload:bits>>
      case bit_array.byte_size(payload) == protocol.max_payload {
        True -> read_loop(reader, acc)
        False -> Ok(#(sequence, acc, reader))
      }
    }
    Error(Nil) -> {
      // Once the header is in, wait for the rest of the packet in one read
      // rather than growing the buffer a chunk at a time.
      let wanted = case reader.buffer {
        <<size:little-size(24), _sequence, rest:bits>> ->
          size - bit_array.byte_size(rest)
        _ -> 0
      }
      use data <- result.try(recv(reader.socket, wanted, reader.deadline))
      read_loop(
        Reader(..reader, buffer: <<reader.buffer:bits, data:bits>>),
        acc,
      )
    }
  }
}

/// `length` bytes, or whatever is available when it is 0.
fn recv(
  socket: Socket,
  length: Int,
  deadline: Int,
) -> Result(BitArray, sql.Error) {
  case remaining(deadline) {
    0 -> Error(sql.QueryTimeout)
    timeout ->
      case tcp.recv(socket, length, timeout) {
        Ok(data) -> Ok(data)
        Error(tcp.Timeout) -> Error(sql.QueryTimeout)
        Error(tcp.Closed) -> Error(sql.ConnectionLost("closed by the server"))
        Error(tcp.Failed(reason)) -> Error(sql.ConnectionLost(reason))
      }
  }
}

fn remaining(deadline: Int) -> Int {
  int.max(deadline - now_ms(), 0)
}

fn malformed() -> sql.Error {
  sql.ConnectionLost("malformed packet from the server")
}

fn error_packet(payload: BitArray) -> sql.Error {
  case protocol.response(payload) {
    Ok(protocol.ErrPacket(error)) -> server_error(error)
    _ -> malformed()
  }
}

/// Map a server error onto `sql.Error`, by MySQL error number.
pub fn server_error(error: ServerError) -> sql.Error {
  let message = error.message
  case error.code {
    // ER_DUP_ENTRY: "Duplicate entry 'x' for key 'table.name'"
    1062 ->
      sql.UniqueViolation(
        constraint: quoted_after(message, "for key '")
          |> unqualify,
        message:,
      )
    // ER_ROW_IS_REFERENCED_2, ER_NO_REFERENCED_ROW_2
    1451 | 1452 ->
      sql.ForeignKeyViolation(
        constraint: between(message, "CONSTRAINT `", "`"),
        message:,
      )
    // ER_BAD_NULL_ERROR, ER_NO_DEFAULT_FOR_FIELD
    1048 ->
      sql.NotNullViolation(column: between(message, "Column '", "'"), message:)
    1364 ->
      sql.NotNullViolation(column: between(message, "Field '", "'"), message:)
    // ER_CHECK_CONSTRAINT_VIOLATED
    3819 ->
      sql.CheckViolation(
        constraint: between(message, "Check constraint '", "'"),
        message:,
      )
    // Server shutdown, connection killed: the connection is gone.
    1053 | 1927 | 4031 -> sql.ConnectionLost(message)
    code -> sql.QueryFailed(code: int.to_string(code), message:)
  }
}

/// The text between `start` and the last `'` after it, for values that may
/// themselves contain quotes.
fn quoted_after(message: String, start: String) -> String {
  case string.split_once(message, start) {
    Ok(#(_, rest)) ->
      case string.ends_with(rest, "'") {
        True -> string.drop_end(rest, 1)
        False -> between(rest, "", "'")
      }
    Error(Nil) -> ""
  }
}

fn between(message: String, start: String, end: String) -> String {
  let after = case start {
    "" -> Ok(message)
    _ -> string.split_once(message, start) |> result.map(fn(pair) { pair.1 })
  }
  case after {
    Ok(rest) ->
      case string.split_once(rest, end) {
        Ok(#(value, _)) -> value
        Error(Nil) -> rest
      }
    Error(Nil) -> ""
  }
}

/// MySQL 8 names a key `table.key`; the key's own name is wanted.
fn unqualify(name: String) -> String {
  case string.split(name, ".") |> list.last {
    Ok(last) -> last
    Error(Nil) -> name
  }
}

fn now_ms() -> Int {
  runtime.monotonic_ms()
}

@external(erlang, "gloss@mysql_ffi", "rsa_encrypt")
fn ffi_rsa_encrypt(pem: BitArray, data: BitArray) -> Result(BitArray, Nil)

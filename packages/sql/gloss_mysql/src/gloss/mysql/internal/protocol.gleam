//// The MySQL client/server protocol's packets: framing, length-encoded
//// values, the handshake, OK/ERR/EOF and column definitions, and the
//// commands the driver sends. Pure functions over bit arrays, so they can
//// be tested without a server.
////
//// Every packet is a 3-byte little-endian payload length, a sequence id
//// and the payload. A payload of 16 MiB - 1 bytes or more is split over
//// several packets, each full one followed by the next, ending with one
//// shorter than the maximum (possibly empty).

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The largest payload one packet carries.
pub const max_payload = 16_777_215

// --- Capability and status flags ---------------------------------------------

pub const client_long_password = 0x1

pub const client_found_rows = 0x2

pub const client_long_flag = 0x4

pub const client_connect_with_db = 0x8

pub const client_protocol_41 = 0x200

pub const client_ssl = 0x800

pub const client_transactions = 0x2000

pub const client_secure_connection = 0x8000

pub const client_multi_statements = 0x10000

pub const client_multi_results = 0x20000

pub const client_ps_multi_results = 0x40000

pub const client_plugin_auth = 0x80000

pub const client_plugin_auth_lenenc_client_data = 0x200000

pub const client_deprecate_eof = 0x1000000

/// Another result set follows this one.
pub const server_more_results_exists = 0x8

/// utf8mb4_general_ci: full UTF-8, and known to MySQL 5.7, 8 and MariaDB.
pub const charset_utf8mb4 = 45

/// The `binary` character set: a column of bytes, not text.
pub const charset_binary = 63

/// What the driver asks the server for. `client_ssl` is added when TLS is
/// negotiated and `client_connect_with_db` when a database is named.
pub fn capabilities() -> Int {
  client_long_password
  + client_found_rows
  + client_long_flag
  + client_protocol_41
  + client_transactions
  + client_secure_connection
  + client_multi_statements
  + client_multi_results
  + client_ps_multi_results
  + client_plugin_auth
  + client_plugin_auth_lenenc_client_data
  + client_deprecate_eof
}

pub fn has(flags: Int, flag: Int) -> Bool {
  int.bitwise_and(flags, flag) != 0
}

// --- Framing -----------------------------------------------------------------

/// `payload` as one or more packets, numbered from `sequence`. Returns the
/// bytes and the sequence id the next packet should have.
pub fn frame(payload: BitArray, sequence: Int) -> #(BytesTree, Int) {
  frame_loop(payload, sequence, bytes_tree.new())
}

fn frame_loop(
  payload: BitArray,
  sequence: Int,
  acc: BytesTree,
) -> #(BytesTree, Int) {
  let size = bit_array.byte_size(payload)
  case size >= max_payload {
    False -> #(
      bytes_tree.append(acc, header(size, sequence))
        |> bytes_tree.append(payload),
      next(sequence),
    )
    True -> {
      let assert Ok(head) = bit_array.slice(payload, 0, max_payload)
      let assert Ok(rest) =
        bit_array.slice(payload, max_payload, size - max_payload)
      let acc =
        bytes_tree.append(acc, header(max_payload, sequence))
        |> bytes_tree.append(head)
      frame_loop(rest, next(sequence), acc)
    }
  }
}

fn header(size: Int, sequence: Int) -> BitArray {
  <<size:little-size(24), sequence:size(8)>>
}

pub fn next(sequence: Int) -> Int {
  { sequence + 1 } % 256
}

/// One physical packet off the front of `buffer`: its sequence id, its
/// payload and the bytes after it. `Error(Nil)` until it has all arrived.
pub fn take_packet(
  buffer: BitArray,
) -> Result(#(Int, BitArray, BitArray), Nil) {
  case buffer {
    <<size:little-size(24), sequence:size(8), rest:bits>> ->
      case bit_array.byte_size(rest) >= size {
        True -> {
          let assert <<payload:bytes-size(size), rest:bits>> = rest
          Ok(#(sequence, payload, rest))
        }
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// --- Length-encoded values ---------------------------------------------------

/// A length-encoded integer: `Ok(None)` is the `NULL` marker (0xFB).
pub fn lenenc_int(data: BitArray) -> Result(#(Option(Int), BitArray), Nil) {
  case data {
    <<0xFB, rest:bits>> -> Ok(#(None, rest))
    <<0xFC, n:little-size(16), rest:bits>> -> Ok(#(Some(n), rest))
    <<0xFD, n:little-size(24), rest:bits>> -> Ok(#(Some(n), rest))
    <<0xFE, n:little-size(64), rest:bits>> -> Ok(#(Some(n), rest))
    <<0xFF, _:bits>> -> Error(Nil)
    <<n, rest:bits>> -> Ok(#(Some(n), rest))
    _ -> Error(Nil)
  }
}

/// A length-encoded integer that may not be `NULL`.
pub fn lenenc_count(data: BitArray) -> Result(#(Int, BitArray), Nil) {
  case lenenc_int(data) {
    Ok(#(Some(n), rest)) -> Ok(#(n, rest))
    _ -> Error(Nil)
  }
}

/// A length-encoded string's bytes, or `None` for `NULL`.
pub fn lenenc_bytes(
  data: BitArray,
) -> Result(#(Option(BitArray), BitArray), Nil) {
  case lenenc_int(data) {
    Ok(#(None, rest)) -> Ok(#(None, rest))
    Ok(#(Some(size), rest)) ->
      case rest {
        <<value:bytes-size(size), rest:bits>> -> Ok(#(Some(value), rest))
        _ -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
}

fn lenenc_string(data: BitArray) -> Result(#(String, BitArray), Nil) {
  case lenenc_bytes(data) {
    Ok(#(Some(bytes), rest)) ->
      bit_array.to_string(bytes) |> result.map(fn(s) { #(s, rest) })
    Ok(#(None, rest)) -> Ok(#("", rest))
    Error(Nil) -> Error(Nil)
  }
}

pub fn encode_lenenc_int(n: Int) -> BitArray {
  case n {
    _ if n < 0xFB -> <<n>>
    _ if n < 0x10000 -> <<0xFC, n:little-size(16)>>
    _ if n < 0x1000000 -> <<0xFD, n:little-size(24)>>
    _ -> <<0xFE, n:little-size(64)>>
  }
}

pub fn encode_lenenc_bytes(bytes: BitArray) -> BitArray {
  <<encode_lenenc_int(bit_array.byte_size(bytes)):bits, bytes:bits>>
}

/// The bytes before the first zero byte, and those after it.
pub fn nul_terminated(data: BitArray) -> Result(#(BitArray, BitArray), Nil) {
  nul_loop(data, 0)
}

fn nul_loop(data: BitArray, at: Int) -> Result(#(BitArray, BitArray), Nil) {
  case bit_array.slice(data, at, 1) {
    Ok(<<0>>) -> {
      let assert Ok(head) = bit_array.slice(data, 0, at)
      let size = bit_array.byte_size(data) - at - 1
      let assert Ok(rest) = bit_array.slice(data, at + 1, size)
      Ok(#(head, rest))
    }
    Ok(_) -> nul_loop(data, at + 1)
    Error(Nil) -> Error(Nil)
  }
}

// --- The handshake -----------------------------------------------------------

/// The server's greeting (protocol version 10).
pub type Handshake {
  Handshake(
    server_version: String,
    connection_id: Int,
    capabilities: Int,
    /// The 20-byte nonce authentication is computed over.
    scramble: BitArray,
    /// The authentication plugin the server suggests first.
    plugin: String,
  )
}

pub fn handshake(payload: BitArray) -> Result(Handshake, Nil) {
  case payload {
    <<10, rest:bits>> -> {
      use #(version, rest) <- result.try(nul_terminated(rest))
      use version <- result.try(bit_array.to_string(version))
      case rest {
        <<
          id:little-size(32),
          part1:bytes-size(8),
          _filler,
          low:little-size(16),
          _charset,
          _status:little-size(16),
          high:little-size(16),
          auth_size,
          _reserved:bytes-size(10),
          rest:bits,
        >> -> {
          let capabilities = low + high * 65_536
          let part2_size = int.max(13, auth_size - 8)
          let #(part2, rest) = case rest {
            <<part2:bytes-size(part2_size), rest:bits>> -> #(part2, rest)
            _ -> #(rest, <<>>)
          }
          // The second part is 12 bytes of nonce and a terminating zero.
          let part2 = bit_array.slice(part2, 0, 12) |> result.unwrap(part2)
          let plugin = case nul_terminated(rest) {
            Ok(#(name, _)) -> name
            Error(Nil) -> rest
          }
          Ok(Handshake(
            server_version: version,
            connection_id: id,
            capabilities:,
            scramble: <<part1:bits, part2:bits>>,
            plugin: bit_array.to_string(plugin)
              |> result.unwrap("mysql_native_password"),
          ))
        }
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// The start of a handshake response, sent alone to ask for TLS.
pub fn ssl_request(capabilities: Int) -> BitArray {
  <<
    capabilities:little-size(32),
    max_payload:little-size(32),
    charset_utf8mb4,
    0:size(184),
  >>
}

/// The client's reply to the greeting.
pub fn handshake_response(
  capabilities: Int,
  user: String,
  auth: BitArray,
  database: Option(String),
  plugin: String,
) -> BitArray {
  let database = case database {
    Some(name) -> <<name:utf8, 0>>
    None -> <<>>
  }
  <<
    ssl_request(capabilities):bits,
    user:utf8,
    0,
    encode_lenenc_bytes(auth):bits,
    database:bits,
    plugin:utf8,
    0,
  >>
}

// --- Generic responses -------------------------------------------------------

pub type Response {
  OkPacket(affected: Int, last_insert_id: Int, status: Int)
  ErrPacket(ServerError)
  /// An end of rows, sent when DEPRECATE_EOF isn't honoured.
  EofPacket(status: Int)
}

pub type ServerError {
  ServerError(code: Int, state: String, message: String)
}

/// An OK, ERR or EOF packet. Rows and other payloads are `Error(Nil)`.
pub fn response(payload: BitArray) -> Result(Response, Nil) {
  case payload {
    <<0xFF, code:little-size(16), rest:bits>> ->
      Ok(ErrPacket(server_error(code, rest)))
    <<0xFE, _:bits>> ->
      case bit_array.byte_size(payload) < 9 {
        True ->
          case payload {
            <<0xFE, _warnings:little-size(16), status:little-size(16), _:bits>> ->
              Ok(EofPacket(status:))
            _ -> Ok(EofPacket(status: 0))
          }
        False -> ok_body(payload)
      }
    <<0x00, _:bits>> -> ok_body(payload)
    _ -> Error(Nil)
  }
}

fn ok_body(payload: BitArray) -> Result(Response, Nil) {
  let assert <<_header, rest:bits>> = payload
  use #(affected, rest) <- result.try(lenenc_count(rest))
  use #(last_insert_id, rest) <- result.try(lenenc_count(rest))
  let status = case rest {
    <<status:little-size(16), _:bits>> -> status
    _ -> 0
  }
  Ok(OkPacket(affected:, last_insert_id:, status:))
}

fn server_error(code: Int, rest: BitArray) -> ServerError {
  let #(state, message) = case rest {
    <<"#":utf8, state:bytes-size(5), message:bits>> -> #(state, message)
    _ -> #(<<>>, rest)
  }
  ServerError(
    code:,
    state: bit_array.to_string(state) |> result.unwrap(""),
    message: bit_array.to_string(message) |> result.unwrap(""),
  )
}

/// Whether a payload ends a run of rows: an EOF or OK packet with the 0xFE
/// header. A row can't be mistaken for one, as a row starting 0xFE would be
/// at least 16 MiB long.
pub fn is_terminator(payload: BitArray) -> Bool {
  case payload {
    <<0xFE, _:bits>> -> bit_array.byte_size(payload) < max_payload
    _ -> False
  }
}

// --- Column definitions ------------------------------------------------------

pub type Column {
  Column(
    name: String,
    /// The `MYSQL_TYPE_*` code.
    type_: Int,
    flags: Int,
    charset: Int,
    /// The column's display length, e.g. 1 for `TINYINT(1)`.
    length: Int,
    decimals: Int,
  )
}

pub const flag_unsigned = 32

pub fn column(payload: BitArray) -> Result(Column, Nil) {
  use #(_catalog, rest) <- result.try(lenenc_string(payload))
  use #(_schema, rest) <- result.try(lenenc_string(rest))
  use #(_table, rest) <- result.try(lenenc_string(rest))
  use #(_org_table, rest) <- result.try(lenenc_string(rest))
  use #(name, rest) <- result.try(lenenc_string(rest))
  use #(_org_name, rest) <- result.try(lenenc_string(rest))
  use #(_fixed, rest) <- result.try(lenenc_count(rest))
  case rest {
    <<
      charset:little-size(16),
      length:little-size(32),
      type_,
      flags:little-size(16),
      decimals,
      _:bits,
    >> -> Ok(Column(name:, type_:, flags:, charset:, length:, decimals:))
    _ -> Error(Nil)
  }
}

// --- Commands ----------------------------------------------------------------

pub fn quit() -> BitArray {
  <<0x01>>
}

pub fn query(sql: String) -> BitArray {
  <<0x03, sql:utf8>>
}

pub fn prepare(sql: String) -> BitArray {
  <<0x16, sql:utf8>>
}

/// The first packet of a reply to `prepare`.
pub type Prepared {
  Prepared(id: Int, columns: Int, params: Int)
}

pub fn prepared(payload: BitArray) -> Result(Prepared, Nil) {
  case payload {
    <<
      0x00,
      id:little-size(32),
      columns:little-size(16),
      params:little-size(16),
      _:bits,
    >> -> Ok(Prepared(id:, columns:, params:))
    _ -> Error(Nil)
  }
}

/// A statement argument: its `MYSQL_TYPE_*`, whether it is unsigned, and
/// its binary value (`None` for `NULL`).
pub type Param {
  Param(type_: Int, unsigned: Bool, value: Option(BitArray))
}

/// Run prepared statement `id` with `params`, without a cursor.
pub fn execute(id: Int, params: List(Param)) -> BitArray {
  let head = <<0x17, id:little-size(32), 0, 1:little-size(32)>>
  case params {
    [] -> head
    _ -> {
      let nulls = null_bitmap(list.map(params, fn(p) { p.value == None }), 0)
      let types =
        list.map(params, fn(p) {
          let unsigned = case p.unsigned {
            True -> 0x80
            False -> 0
          }
          <<p.type_, unsigned>>
        })
        |> bit_array.concat
      let values =
        list.filter_map(params, fn(p) { option.to_result(p.value, Nil) })
      <<head:bits, nulls:bits, 1, types:bits, bit_array.concat(values):bits>>
    }
  }
}

/// A NULL bitmap: bit `offset + i` is set when entry `i` is `True`.
pub fn null_bitmap(nulls: List(Bool), offset: Int) -> BitArray {
  let size = { list.length(nulls) + offset + 7 } / 8
  let bits =
    list.index_fold(nulls, 0, fn(acc, null, i) {
      case null {
        True -> int.bitwise_or(acc, int.bitwise_shift_left(1, i + offset))
        False -> acc
      }
    })
  <<bits:little-size({ size * 8 })>>
}

/// Whether bit `i` of a NULL bitmap is set.
pub fn is_null(bitmap: BitArray, i: Int) -> Bool {
  case bit_array.slice(bitmap, i / 8, 1) {
    Ok(<<byte>>) -> int.bitwise_and(byte, int.bitwise_shift_left(1, i % 8)) != 0
    _ -> False
  }
}

pub fn close_statement(id: Int) -> BitArray {
  <<0x19, id:little-size(32)>>
}

/// Ask for the server's RSA public key during caching_sha2_password.
pub fn request_public_key() -> BitArray {
  <<0x02>>
}

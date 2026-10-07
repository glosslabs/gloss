//// Postgres frontend/backend protocol version 3.0 messages: encoding what
//// the client sends and decoding what the server sends. No I/O.
////
//// https://www.postgresql.org/docs/current/protocol-message-formats.html

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// --- Frontend ----------------------------------------------------------------

pub fn ssl_request() -> BytesTree {
  bytes_tree.from_bit_array(<<8:32, 80_877_103:32>>)
}

/// The startup message for protocol 3.0 with `parameters` such as `user`.
pub fn startup(parameters: List(#(String, String))) -> BytesTree {
  let body =
    list.fold(parameters, <<196_608:32>>, fn(acc, parameter) {
      <<acc:bits, cstring(parameter.0):bits, cstring(parameter.1):bits>>
    })
  let body = <<body:bits, 0>>
  bytes_tree.from_bit_array(<<{ bit_array.byte_size(body) + 4 }:32, body:bits>>)
}

pub fn password(password: String) -> BytesTree {
  message("p", cstring(password))
}

pub fn sasl_initial_response(mechanism: String, data: BitArray) -> BytesTree {
  message("p", <<
    cstring(mechanism):bits,
    { bit_array.byte_size(data) }:32,
    data:bits,
  >>)
}

pub fn sasl_response(data: BitArray) -> BytesTree {
  message("p", data)
}

/// Parse into the statement `name` (`""` for the unnamed one), leaving
/// every parameter's type to the server.
pub fn parse(name: String, sql: String) -> BytesTree {
  message("P", <<cstring(name):bits, cstring(sql):bits, 0:16>>)
}

pub fn describe_statement(name: String) -> BytesTree {
  message("D", <<"S":utf8, cstring(name):bits>>)
}

pub fn close_statement(name: String) -> BytesTree {
  message("C", <<"S":utf8, cstring(name):bits>>)
}

pub fn copy_data(data: BitArray) -> BytesTree {
  bytes_tree.from_bit_array(<<
    "d":utf8,
    { bit_array.byte_size(data) + 4 }:32,
    data:bits,
  >>)
}

pub fn copy_done() -> BytesTree {
  message("c", <<>>)
}

/// A parameter: `None` for NULL, or its format (0 text, 1 binary) and bytes.
pub type Parameter =
  Option(#(Int, BitArray))

/// Bind the statement `name` to the unnamed portal, asking for every result
/// column in text format.
pub fn bind(name: String, parameters: List(Parameter)) -> BytesTree {
  let count = list.length(parameters)
  let formats =
    list.fold(parameters, <<>>, fn(acc, parameter) {
      case parameter {
        Some(#(format, _)) -> <<acc:bits, format:16>>
        None -> <<acc:bits, 0:16>>
      }
    })
  let values =
    list.fold(parameters, <<>>, fn(acc, parameter) {
      case parameter {
        Some(#(_, bytes)) -> <<
          acc:bits,
          { bit_array.byte_size(bytes) }:32,
          bytes:bits,
        >>
        None -> <<acc:bits, -1:32>>
      }
    })
  message("B", <<
    0,
    cstring(name):bits,
    count:16,
    formats:bits,
    count:16,
    values:bits,
    0:16,
  >>)
}

pub fn describe_portal() -> BytesTree {
  message("D", <<"P":utf8, 0>>)
}

pub fn execute() -> BytesTree {
  message("E", <<0, 0:32>>)
}

pub fn sync() -> BytesTree {
  message("S", <<>>)
}

/// A simple query: SQL text that may hold several statements.
pub fn query(sql: String) -> BytesTree {
  message("Q", cstring(sql))
}

pub fn copy_fail(reason: String) -> BytesTree {
  message("f", cstring(reason))
}

pub fn terminate() -> BytesTree {
  message("X", <<>>)
}

fn message(tag: String, body: BitArray) -> BytesTree {
  bytes_tree.from_bit_array(<<
    tag:utf8,
    { bit_array.byte_size(body) + 4 }:32,
    body:bits,
  >>)
}

fn cstring(value: String) -> BitArray {
  <<value:utf8, 0>>
}

// --- Backend -----------------------------------------------------------------

pub type Message {
  Authentication(Authentication)
  ParameterStatus(name: String, value: String)
  BackendKeyData(process_id: Int, secret: BitArray)
  /// `status` is `I` when idle, `T` in a transaction and `E` in a failed
  /// one.
  ReadyForQuery(status: String)
  ParseComplete
  BindComplete
  NoData
  RowDescription(columns: List(Column))
  DataRow(values: List(Option(BitArray)))
  CommandComplete(tag: String)
  EmptyQueryResponse
  ErrorResponse(fields: List(#(String, String)))
  NoticeResponse(fields: List(#(String, String)))
  CopyInResponse
  CopyOutResponse
  CopyData(data: BitArray)
  CopyDone
  NotificationResponse(process_id: Int, channel: String, payload: String)
  /// Any message the client has no use for, by its tag byte.
  Other(tag: Int)
}

pub type Authentication {
  AuthenticationOk
  CleartextPassword
  Md5Password(salt: BitArray)
  Sasl(mechanisms: List(String))
  SaslContinue(data: BitArray)
  SaslFinal(data: BitArray)
  UnsupportedAuthentication(code: Int)
}

pub type Column {
  Column(name: String, type_oid: Int)
}

pub type DecodeError {
  /// The buffer ends before the next message does.
  Incomplete
  Malformed
}

/// Split the first message off `buffer`.
pub fn decode(buffer: BitArray) -> Result(#(Message, BitArray), DecodeError) {
  case buffer {
    <<tag, length:32, rest:bytes>> ->
      case length >= 4 {
        False -> Error(Malformed)
        True ->
          case rest {
            <<body:bytes-size(length - 4), rest:bytes>> ->
              decode_body(tag, body) |> result.map(fn(m) { #(m, rest) })
            _ -> Error(Incomplete)
          }
      }
    _ -> Error(Incomplete)
  }
}

fn decode_body(tag: Int, body: BitArray) -> Result(Message, DecodeError) {
  case tag, body {
    // R
    0x52, <<code:32, data:bytes>> ->
      decode_authentication(code, data) |> result.map(Authentication)
    // S
    0x53, _ -> {
      use #(name, rest) <- result.try(read_cstring(body))
      use #(value, _) <- result.map(read_cstring(rest))
      ParameterStatus(name:, value:)
    }
    // K
    0x4B, <<process_id:32, secret:bytes>> ->
      Ok(BackendKeyData(process_id:, secret:))
    // Z
    0x5A, <<status>> ->
      bit_array.to_string(<<status>>)
      |> result.map(ReadyForQuery)
      |> result.replace_error(Malformed)
    // 1, 2, n, I, G
    0x31, _ -> Ok(ParseComplete)
    0x32, _ -> Ok(BindComplete)
    0x6E, _ -> Ok(NoData)
    0x49, _ -> Ok(EmptyQueryResponse)
    0x47, _ -> Ok(CopyInResponse)
    // H, d, c
    0x48, _ -> Ok(CopyOutResponse)
    0x64, _ -> Ok(CopyData(body))
    0x63, _ -> Ok(CopyDone)
    // A
    0x41, <<process_id:32, rest:bytes>> -> {
      use #(channel, rest) <- result.try(read_cstring(rest))
      use #(payload, _) <- result.map(read_cstring(rest))
      NotificationResponse(process_id:, channel:, payload:)
    }
    // T
    0x54, <<count:16, rest:bytes>> ->
      decode_columns(rest, count, []) |> result.map(RowDescription)
    // D
    0x44, <<count:16, rest:bytes>> ->
      decode_values(rest, count, []) |> result.map(DataRow)
    // C
    0x43, _ ->
      read_cstring(body) |> result.map(fn(read) { CommandComplete(read.0) })
    // E, N
    0x45, _ -> decode_fields(body, []) |> result.map(ErrorResponse)
    0x4E, _ -> decode_fields(body, []) |> result.map(NoticeResponse)
    // R, T, D, K, Z, A with a bad body.
    0x52, _ | 0x54, _ | 0x44, _ | 0x4B, _ | 0x5A, _ | 0x41, _ ->
      Error(Malformed)
    _, _ -> Ok(Other(tag))
  }
}

fn decode_authentication(
  code: Int,
  data: BitArray,
) -> Result(Authentication, DecodeError) {
  case code, data {
    0, _ -> Ok(AuthenticationOk)
    3, _ -> Ok(CleartextPassword)
    5, <<salt:bytes-size(4)>> -> Ok(Md5Password(salt))
    10, _ -> decode_strings(data, []) |> result.map(Sasl)
    11, _ -> Ok(SaslContinue(data))
    12, _ -> Ok(SaslFinal(data))
    5, _ -> Error(Malformed)
    _, _ -> Ok(UnsupportedAuthentication(code))
  }
}

/// A list of strings ended by an empty one.
fn decode_strings(
  data: BitArray,
  acc: List(String),
) -> Result(List(String), DecodeError) {
  case data {
    <<0, _:bytes>> | <<>> -> Ok(list.reverse(acc))
    _ -> {
      use #(value, rest) <- result.try(read_cstring(data))
      decode_strings(rest, [value, ..acc])
    }
  }
}

fn decode_columns(
  data: BitArray,
  count: Int,
  acc: List(Column),
) -> Result(List(Column), DecodeError) {
  case count {
    0 -> Ok(list.reverse(acc))
    _ -> {
      use #(name, rest) <- result.try(read_cstring(data))
      case rest {
        <<
          _table:32,
          _attribute:16,
          type_oid:32,
          _size:16,
          _modifier:32,
          _format:16,
          rest:bytes,
        >> -> decode_columns(rest, count - 1, [Column(name:, type_oid:), ..acc])
        _ -> Error(Malformed)
      }
    }
  }
}

fn decode_values(
  data: BitArray,
  count: Int,
  acc: List(Option(BitArray)),
) -> Result(List(Option(BitArray)), DecodeError) {
  case count, data {
    0, _ -> Ok(list.reverse(acc))
    _, <<-1:32-signed, rest:bytes>> ->
      decode_values(rest, count - 1, [None, ..acc])
    _, <<length:32, value:bytes-size(length), rest:bytes>> ->
      decode_values(rest, count - 1, [Some(value), ..acc])
    _, _ -> Error(Malformed)
  }
}

fn decode_fields(
  data: BitArray,
  acc: List(#(String, String)),
) -> Result(List(#(String, String)), DecodeError) {
  case data {
    <<0, _:bytes>> | <<>> -> Ok(list.reverse(acc))
    <<code, rest:bytes>> -> {
      use code <- result.try(
        bit_array.to_string(<<code>>) |> result.replace_error(Malformed),
      )
      use #(value, rest) <- result.try(read_cstring(rest))
      decode_fields(rest, [#(code, value), ..acc])
    }
    _ -> Error(Malformed)
  }
}

fn read_cstring(data: BitArray) -> Result(#(String, BitArray), DecodeError) {
  case split_at_nul(data, 0) {
    Ok(length) ->
      case data {
        <<value:bytes-size(length), 0, rest:bytes>> ->
          bit_array.to_string(value)
          |> result.map(fn(value) { #(value, rest) })
          |> result.replace_error(Malformed)
        _ -> Error(Malformed)
      }
    Error(Nil) -> Error(Malformed)
  }
}

fn split_at_nul(data: BitArray, index: Int) -> Result(Int, Nil) {
  case bit_array.slice(data, index, 1) {
    Ok(<<0>>) -> Ok(index)
    Ok(_) -> split_at_nul(data, index + 1)
    Error(Nil) -> Error(Nil)
  }
}

//// WebSocket frames (RFC 6455), with no IO: parsing what clients send,
//// encoding what the server sends, and the opening handshake's key.

import gleam/bit_array
import gleam/crypto
import gleam/int

pub type Opcode {
  Continuation
  TextFrame
  BinaryFrame
  CloseFrame
  PingFrame
  PongFrame
}

pub type Frame {
  /// `compressed` is the RSV1 bit: the first frame of a message compressed
  /// with `permessage-deflate`.
  Frame(fin: Bool, opcode: Opcode, payload: BitArray, compressed: Bool)
}

pub type ParseError {
  /// More bytes are needed before a whole frame is available.
  Incomplete
  /// The frame breaks the protocol; close with this code.
  Invalid(code: Int, reason: String)
}

/// The first whole frame in `data` and the bytes after it. Client frames
/// must be masked; payloads longer than `max_payload` are refused with 1009.
/// RSV1 is allowed on a text or binary frame only when `deflate` was
/// negotiated; the other reserved bits never are.
pub fn parse(
  data: BitArray,
  max_payload: Int,
  deflate: Bool,
) -> Result(#(Frame, BitArray), ParseError) {
  case data {
    <<
      fin:size(1),
      rsv:size(3),
      opcode:size(4),
      masked:size(1),
      len:size(7),
      rest:bits,
    >> -> {
      use opcode <- result_try(decode_opcode(opcode))
      use #(length, rest) <- result_try(payload_length(len, rest))
      let compressed = rsv == 4
      let rsv1_allowed = case opcode {
        TextFrame | BinaryFrame -> deflate
        _ -> False
      }
      case rsv, masked, opcode, fin {
        4, _, _, _ if !rsv1_allowed -> Error(Invalid(1002, "reserved bits set"))
        r, _, _, _ if r != 0 && r != 4 ->
          Error(Invalid(1002, "reserved bits set"))
        _, 0, _, _ -> Error(Invalid(1002, "client frames must be masked"))
        _, _, CloseFrame, _
        | _, _, PingFrame, _
        | _, _, PongFrame, _
          if length > 125
        -> Error(Invalid(1002, "control frame too long"))
        _, _, CloseFrame, 0 | _, _, PingFrame, 0 | _, _, PongFrame, 0 ->
          Error(Invalid(1002, "fragmented control frame"))
        _, _, _, _ if length > max_payload ->
          Error(Invalid(1009, "message too big"))
        _, _, _, _ ->
          case rest {
            <<key:bytes-size(4), payload:bytes-size(length), after:bits>> ->
              Ok(#(
                Frame(
                  fin: fin == 1,
                  opcode:,
                  payload: unmask(key, payload),
                  compressed:,
                ),
                after,
              ))
            _ -> Error(Incomplete)
          }
      }
    }
    _ -> Error(Incomplete)
  }
}

fn payload_length(
  len: Int,
  rest: BitArray,
) -> Result(#(Int, BitArray), ParseError) {
  case len, rest {
    126, <<length:size(16), rest:bits>> -> Ok(#(length, rest))
    127, <<0:size(1), length:size(63), rest:bits>> -> Ok(#(length, rest))
    127, <<1:size(1), _:size(63), _:bits>> ->
      Error(Invalid(1002, "invalid payload length"))
    126, _ | 127, _ -> Error(Incomplete)
    length, _ -> Ok(#(length, rest))
  }
}

fn decode_opcode(opcode: Int) -> Result(Opcode, ParseError) {
  case opcode {
    0 -> Ok(Continuation)
    1 -> Ok(TextFrame)
    2 -> Ok(BinaryFrame)
    8 -> Ok(CloseFrame)
    9 -> Ok(PingFrame)
    10 -> Ok(PongFrame)
    _ -> Error(Invalid(1002, "unknown opcode " <> int.to_string(opcode)))
  }
}

/// An unfragmented, unmasked server frame.
pub fn encode(opcode: Opcode, payload: BitArray) -> BitArray {
  encode_frame(opcode, payload, 0)
}

/// An unfragmented server frame whose payload is compressed with
/// `permessage-deflate` (RSV1 set).
pub fn encode_compressed(opcode: Opcode, payload: BitArray) -> BitArray {
  encode_frame(opcode, payload, 4)
}

fn encode_frame(opcode: Opcode, payload: BitArray, rsv: Int) -> BitArray {
  let code = case opcode {
    Continuation -> 0
    TextFrame -> 1
    BinaryFrame -> 2
    CloseFrame -> 8
    PingFrame -> 9
    PongFrame -> 10
  }
  let size = bit_array.byte_size(payload)
  let length = case size {
    n if n < 126 -> <<n:size(7)>>
    n if n < 65_536 -> <<126:size(7), n:size(16)>>
    n -> <<127:size(7), n:size(64)>>
  }
  <<1:size(1), rsv:size(3), code:size(4), 0:size(1), length:bits, payload:bits>>
}

/// A close frame's payload: a status code and an optional reason.
pub fn close_payload(code: Int, reason: String) -> BitArray {
  <<code:size(16), reason:utf8>>
}

/// The status code in a received close frame's payload; 1005 (no status)
/// when it has none.
pub fn close_code(payload: BitArray) -> Int {
  case payload {
    <<code:size(16), _:bits>> -> code
    _ -> 1005
  }
}

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

/// The `sec-websocket-accept` answer to a client's `sec-websocket-key`.
pub fn accept_key(key: String) -> String {
  crypto.hash(crypto.Sha1, bit_array.from_string(key <> guid))
  |> bit_array.base64_encode(True)
}

fn result_try(
  result: Result(a, ParseError),
  next: fn(a) -> Result(b, ParseError),
) -> Result(b, ParseError) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

@external(erlang, "gloss@http@server_ffi", "unmask")
fn unmask(key: BitArray, payload: BitArray) -> BitArray

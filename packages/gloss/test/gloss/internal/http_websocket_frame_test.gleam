import gleeunit/should
import gloss/internal/http_websocket_frame.{
  BinaryFrame, Frame, Incomplete, Invalid, PingFrame, TextFrame,
} as frame

const key = <<1, 2, 3, 4>>

/// A masked client frame, as browsers send.
fn client(fin: Int, opcode: Int, payload: BitArray) -> BitArray {
  let size = bit_array_size(payload)
  let length = case size {
    n if n < 126 -> <<n:size(7)>>
    n -> <<126:size(7), n:size(16)>>
  }
  <<
    fin:size(1),
    0:size(3),
    opcode:size(4),
    1:size(1),
    length:bits,
    key:bits,
    { xor(payload) }:bits,
  >>
}

fn xor(payload: BitArray) -> BitArray {
  mask(key, payload)
}

pub fn accept_key_test() {
  // The example from RFC 6455, section 1.3.
  frame.accept_key("dGhlIHNhbXBsZSBub25jZQ==")
  |> should.equal("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
}

pub fn parse_masked_text_test() {
  frame.parse(<<client(1, 1, <<"hello":utf8>>):bits, "rest":utf8>>, 1000)
  |> should.equal(
    Ok(
      #(Frame(fin: True, opcode: TextFrame, payload: <<"hello":utf8>>), <<
        "rest":utf8,
      >>),
    ),
  )
}

pub fn parse_extended_length_test() {
  let payload = repeat(<<"ab":utf8>>, 100)
  let assert Ok(#(Frame(opcode: BinaryFrame, payload: got, ..), <<>>)) =
    frame.parse(client(1, 2, payload), 1000)
  got |> should.equal(payload)
}

pub fn parse_incomplete_test() {
  let whole = client(1, 1, <<"hello":utf8>>)
  frame.parse(<<>>, 1000) |> should.equal(Error(Incomplete))
  frame.parse(slice(whole, 3), 1000) |> should.equal(Error(Incomplete))
}

pub fn protocol_errors_test() {
  // Unmasked.
  frame.parse(<<1:1, 0:3, 1:4, 0:1, 2:7, "hi":utf8>>, 1000)
  |> should.equal(Error(Invalid(1002, "client frames must be masked")))
  // Reserved bits.
  frame.parse(<<1:1, 4:3, 1:4, 1:1, 0:7, key:bits>>, 1000)
  |> should.equal(Error(Invalid(1002, "reserved bits set")))
  // Fragmented control frame.
  frame.parse(client(0, 9, <<>>), 1000)
  |> should.equal(Error(Invalid(1002, "fragmented control frame")))
  // Too big.
  frame.parse(client(1, 2, <<"hello":utf8>>), 4)
  |> should.equal(Error(Invalid(1009, "message too big")))
  // Unknown opcode.
  frame.parse(client(1, 3, <<>>), 1000)
  |> should.equal(Error(Invalid(1002, "unknown opcode 3")))
}

pub fn encode_test() {
  frame.encode(TextFrame, <<"hi":utf8>>)
  |> should.equal(<<0x81, 2, "hi":utf8>>)
  frame.encode(PingFrame, <<>>) |> should.equal(<<0x89, 0>>)
  let payload = repeat(<<"x":utf8>>, 200)
  frame.encode(BinaryFrame, payload)
  |> should.equal(<<0x82, 126, 200:size(16), payload:bits>>)
}

pub fn close_payload_test() {
  frame.close_payload(1001, "bye") |> should.equal(<<1001:16, "bye":utf8>>)
  frame.close_code(<<1000:16>>) |> should.equal(1000)
  frame.close_code(<<>>) |> should.equal(1005)
}

fn repeat(piece: BitArray, times: Int) -> BitArray {
  case times {
    0 -> <<>>
    _ -> <<piece:bits, repeat(piece, times - 1):bits>>
  }
}

@external(erlang, "erlang", "byte_size")
fn bit_array_size(data: BitArray) -> Int

@external(erlang, "binary", "part")
fn part(data: BitArray, start: Int, length: Int) -> BitArray

fn slice(data: BitArray, length: Int) -> BitArray {
  part(data, 0, length)
}

@external(erlang, "gloss@http@server_ffi", "unmask")
fn mask(key: BitArray, payload: BitArray) -> BitArray

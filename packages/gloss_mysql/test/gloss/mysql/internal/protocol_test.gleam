import gleam/bit_array
import gleam/bytes_tree
import gleam/option.{None, Some}
import gloss/mysql/internal/protocol.{Param}

pub fn frames_a_small_payload_test() {
  let #(data, next) = protocol.frame(<<1, 2, 3>>, 0)
  assert bytes_tree.to_bit_array(data) == <<3, 0, 0, 0, 1, 2, 3>>
  assert next == 1
  assert protocol.take_packet(<<3, 0, 0, 7, 1, 2, 3, 9>>)
    == Ok(#(7, <<1, 2, 3>>, <<9>>))
  // Not all here yet.
  assert protocol.take_packet(<<3, 0, 0, 7, 1, 2>>) == Error(Nil)
  assert protocol.take_packet(<<3, 0>>) == Error(Nil)
}

pub fn splits_payloads_of_16_mib_and_more_test() {
  let payload = <<0:size({ protocol.max_payload * 8 }), 5, 6>>
  let #(data, next) = protocol.frame(payload, 3)
  let data = bytes_tree.to_bit_array(data)
  let assert Ok(#(3, first, rest)) = protocol.take_packet(data)
  assert bit_array.byte_size(first) == protocol.max_payload
  assert protocol.take_packet(rest) == Ok(#(4, <<5, 6>>, <<>>))
  assert next == 5

  // Exactly the maximum is followed by an empty packet.
  let exact = <<0:size({ protocol.max_payload * 8 })>>
  let #(data, _) = protocol.frame(exact, 255)
  let assert Ok(#(255, _, rest)) =
    protocol.take_packet(bytes_tree.to_bit_array(data))
  assert rest == <<0, 0, 0, 0>>
}

pub fn length_encoded_integers_test() {
  [0, 250, 251, 65_535, 65_536, 16_777_215, 16_777_216, 1_099_511_627_776]
  |> each(fn(n) {
    assert protocol.lenenc_count(<<protocol.encode_lenenc_int(n):bits, 7>>)
      == Ok(#(n, <<7>>))
  })
  assert protocol.lenenc_int(<<0xFB, 1>>) == Ok(#(None, <<1>>))
  assert protocol.lenenc_bytes(<<3, "abc":utf8, 0>>)
    == Ok(#(Some(<<"abc":utf8>>), <<0>>))
  assert protocol.lenenc_bytes(<<3, "ab":utf8>>) == Error(Nil)
}

pub fn parses_the_greeting_test() {
  let payload = <<
    10,
    "8.4.0":utf8,
    0,
    42:little-size(32),
    "abcdefgh":utf8,
    0,
    0xFFFF:little-size(16),
    45,
    2:little-size(16),
    0x01FF:little-size(16),
    21,
    0:size(80),
    "ijklmnopqrst":utf8,
    0,
    "caching_sha2_password":utf8,
    0,
  >>
  let assert Ok(greeting) = protocol.handshake(payload)
  assert greeting.server_version == "8.4.0"
  assert greeting.connection_id == 42
  assert greeting.scramble == <<"abcdefghijklmnopqrst":utf8>>
  assert greeting.plugin == "caching_sha2_password"
  assert protocol.has(greeting.capabilities, protocol.client_protocol_41)
  assert protocol.has(greeting.capabilities, protocol.client_deprecate_eof)
  assert protocol.handshake(<<9>>) == Error(Nil)
}

pub fn the_handshake_response_test() {
  let caps = protocol.capabilities()
  let response =
    protocol.handshake_response(caps, "app", <<1, 2>>, Some("db"), "plugin")
  assert response
    == <<
      caps:little-size(32),
      16_777_215:little-size(32),
      45,
      0:size(184),
      "app":utf8,
      0,
      2,
      1,
      2,
      "db":utf8,
      0,
      "plugin":utf8,
      0,
    >>
}

pub fn ok_err_and_eof_packets_test() {
  assert protocol.response(<<0, 3, 0xFC, 0, 1, 2:little-size(16), 0, 0>>)
    == Ok(protocol.OkPacket(affected: 3, last_insert_id: 256, status: 2))
  assert protocol.response(<<0xFF, 0x7A, 0x04, "#42S02":utf8, "nope":utf8>>)
    == Ok(protocol.ErrPacket(protocol.ServerError(1146, "42S02", "nope")))
  assert protocol.response(<<0xFE, 0, 0, 8, 0>>)
    == Ok(protocol.EofPacket(status: 8))
  // An OK packet ending rows, with DEPRECATE_EOF, also starts with 0xFE.
  assert protocol.response(<<0xFE, 0, 0, 0, 0, 0, 0, 0, 0, 0>>)
    == Ok(protocol.OkPacket(affected: 0, last_insert_id: 0, status: 0))
  assert protocol.is_terminator(<<0xFE, 0, 0, 2, 0>>)
  assert !protocol.is_terminator(<<0, 1, 2>>)
  assert protocol.response(<<5, 1>>) == Error(Nil)
}

pub fn column_definitions_test() {
  let lenenc = fn(s) { protocol.encode_lenenc_bytes(<<s:utf8>>) }
  let payload = <<
    lenenc("def"):bits,
    lenenc("gloss"):bits,
    lenenc("t"):bits,
    lenenc("t"):bits,
    lenenc("flag"):bits,
    lenenc("flag"):bits,
    0x0C,
    63:little-size(16),
    1:little-size(32),
    1,
    32:little-size(16),
    0,
    0,
    0,
  >>
  assert protocol.column(payload)
    == Ok(protocol.Column(
      name: "flag",
      type_: 1,
      flags: 32,
      charset: 63,
      length: 1,
      decimals: 0,
    ))
}

pub fn null_bitmaps_test() {
  let bitmap = protocol.null_bitmap([True, False, False, True], 0)
  assert bitmap == <<0b1001>>
  assert protocol.is_null(bitmap, 0)
  assert !protocol.is_null(bitmap, 1)
  assert protocol.is_null(bitmap, 3)
  // Rows offset their bitmap by two bits.
  let row =
    protocol.null_bitmap([False, False, False, False, False, False, True], 2)
  assert bit_array.byte_size(row) == 2
  assert protocol.is_null(row, 8)
}

pub fn execute_packets_test() {
  assert protocol.execute(7, []) == <<0x17, 7, 0, 0, 0, 0, 1, 0, 0, 0>>
  let params = [
    Param(type_: 8, unsigned: False, value: Some(<<5:little-size(64)>>)),
    Param(type_: 6, unsigned: False, value: None),
  ]
  assert protocol.execute(7, params)
    == <<
      0x17,
      7:little-size(32),
      0,
      1:little-size(32),
      0b10,
      1,
      8,
      0,
      6,
      0,
      5:little-size(64),
    >>
}

pub fn nul_terminated_strings_test() {
  assert protocol.nul_terminated(<<"ab":utf8, 0, "c":utf8>>)
    == Ok(#(<<"ab":utf8>>, <<"c":utf8>>))
  assert protocol.nul_terminated(<<"ab":utf8>>) == Error(Nil)
}

fn each(items: List(a), f: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [x, ..rest] -> {
      f(x)
      each(rest, f)
    }
  }
}

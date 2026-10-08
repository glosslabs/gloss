import gleam/bit_array
import gleam/crypto
import gleam/option.{Some}
import gleam/time/calendar
import gleam/time/timestamp
import gloss/mysql/internal/auth
import gloss/mysql/internal/codec
import gloss/mysql/internal/protocol.{type Column, Column}
import gloss/sql

fn column(type_: Int) -> Column {
  Column(name: "c", type_:, flags: 0, charset: 45, length: 20, decimals: 0)
}

/// Encode a value as an argument and read it back as a column of its type.
fn round_trip(value: sql.Value) -> sql.Value {
  let assert Ok(param) = codec.encode(value)
  let assert Some(bytes) = param.value
  let assert Ok(#(decoded, <<>>)) =
    codec.decode_value(column(param.type_), bytes)
  decoded
}

pub fn values_round_trip_test() {
  assert round_trip(sql.Int(-42)) == sql.Int(-42)
  assert round_trip(sql.Int(9_000_000_000)) == sql.Int(9_000_000_000)
  assert round_trip(sql.Float(1.5)) == sql.Float(1.5)
  assert round_trip(sql.Text("héllo")) == sql.Text("héllo")
  let at =
    timestamp.from_unix_seconds_and_nanoseconds(1_704_164_645, 123_456_000)
  assert round_trip(sql.Timestamp(at)) == sql.Timestamp(at)
  let day = calendar.Date(2024, calendar.February, 29)
  assert round_trip(sql.Date(day)) == sql.Date(day)
  let time = calendar.TimeOfDay(3, 4, 5, 500_000_000)
  assert round_trip(sql.Time(time)) == sql.Time(time)
}

pub fn arguments_test() {
  let assert Ok(param) = codec.encode(sql.Null)
  assert param.type_ == codec.type_null
  assert param.value == option.None
  let assert Ok(param) = codec.encode(sql.Bool(True))
  assert param.value == Some(<<1>>)
  // Beyond 64 bits, as text.
  let assert Ok(param) = codec.encode(sql.Int(100_000_000_000_000_000_000))
  assert param.type_ == codec.type_var_string
  // Nanoseconds are kept to microseconds.
  let assert Ok(param) =
    codec.encode(
      sql.Timestamp(timestamp.from_unix_seconds_and_nanoseconds(0, 1999)),
    )
  assert param.value
    == Some(<<11, 1970:little-size(16), 1, 1, 0, 0, 0, 1:little-size(32)>>)
  let assert Error(_) = codec.encode(sql.Array([]))
}

pub fn column_values_test() {
  let unsigned = Column(..column(1), flags: protocol.flag_unsigned)
  assert codec.decode_value(unsigned, <<255>>) == Ok(#(sql.Int(255), <<>>))
  assert codec.decode_value(column(1), <<255>>) == Ok(#(sql.Int(-1), <<>>))
  // TINYINT(1) is a boolean.
  let boolean = Column(..column(1), length: 1)
  assert codec.decode_value(boolean, <<1, 9>>) == Ok(#(sql.Bool(True), <<9>>))
  assert codec.decode_value(column(246), <<5, "12.50":utf8>>)
    == Ok(#(sql.Text("12.50"), <<>>))
  let binary = Column(..column(252), charset: protocol.charset_binary)
  assert codec.decode_value(binary, <<2, 0, 255>>)
    == Ok(#(sql.Bytes(<<0, 255>>), <<>>))
  assert codec.decode_value(column(10), <<0>>)
    == Ok(#(sql.Text("0000-00-00"), <<>>))
  // A TIME past a day is a duration, shown as text.
  assert codec.decode_value(column(11), <<8, 1, 1:little-size(32), 2, 3, 4>>)
    == Ok(#(sql.Text("-26:03:04"), <<>>))
}

pub fn rows_with_nulls_test() {
  let columns = [column(8), column(253), column(8)]
  // Column 1 (bit 3 after the two-bit offset) is NULL.
  let row = <<0, 0b1000, 7:little-size(64), 9:little-size(64)>>
  assert codec.decode_row(columns, row)
    == Ok([sql.Int(7), sql.Null, sql.Int(9)])
}

pub fn native_password_scramble_test() {
  let nonce = <<"01234567890123456789":utf8>>
  assert auth.native_password("", nonce) == <<>>
  let scrambled = auth.native_password("secret", nonce)
  assert bit_array.byte_size(scrambled) == 20
  // XORing back with the nonce-derived half gives SHA1(password).
  let stage1 = crypto.hash(crypto.Sha1, <<"secret":utf8>>)
  let stage2 = crypto.hash(crypto.Sha1, stage1)
  assert auth.xor(
      scrambled,
      crypto.hash(crypto.Sha1, <<nonce:bits, stage2:bits>>),
    )
    == stage1
}

pub fn caching_sha2_scramble_test() {
  let nonce = <<"01234567890123456789":utf8>>
  assert bit_array.byte_size(auth.caching_sha2("secret", nonce)) == 32
  // "ab" and a zero byte, XORed with the nonce repeated: 97^1, 98^2, 0^1.
  assert auth.obfuscated("ab", <<1, 2>>) == <<96, 96, 1>>
}

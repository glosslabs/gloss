//// Values in MySQL's binary protocol: statement arguments out, column
//// values in.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gloss/mysql/internal/protocol.{type Column, type Param, Param}
import gloss/sql

// --- Column types ------------------------------------------------------------

pub const type_decimal = 0

pub const type_tiny = 1

pub const type_short = 2

pub const type_long = 3

pub const type_float = 4

pub const type_double = 5

pub const type_null = 6

pub const type_timestamp = 7

pub const type_longlong = 8

pub const type_int24 = 9

pub const type_date = 10

pub const type_time = 11

pub const type_datetime = 12

pub const type_year = 13

pub const type_newdecimal = 246

pub const type_blob = 252

pub const type_var_string = 253

// --- Arguments ---------------------------------------------------------------

const min_int64 = -9_223_372_036_854_775_808

const max_int64 = 9_223_372_036_854_775_807

/// A value as a statement argument. MySQL has no arrays, so `sql.Array` is
/// refused.
pub fn encode(value: sql.Value) -> Result(Param, String) {
  case value {
    sql.Null -> Ok(Param(type_null, False, None))
    sql.Bool(b) ->
      Ok(Param(
        type_tiny,
        False,
        Some(case b {
          True -> <<1>>
          False -> <<0>>
        }),
      ))
    sql.Int(i) if i >= min_int64 && i <= max_int64 ->
      Ok(Param(type_longlong, False, Some(<<i:little-size(64)>>)))
    // Beyond 64 bits, as text, which a DECIMAL column accepts.
    sql.Int(i) -> Ok(text(int.to_string(i)))
    sql.Float(f) ->
      Ok(Param(type_double, False, Some(<<f:float-little-size(64)>>)))
    sql.Text(s) -> Ok(text(s))
    sql.Bytes(b) ->
      Ok(Param(type_blob, False, Some(protocol.encode_lenenc_bytes(b))))
    sql.Timestamp(t) -> {
      let #(date, time) = timestamp.to_calendar(t, calendar.utc_offset)
      Ok(Param(type_datetime, False, Some(datetime(date, time))))
    }
    sql.Date(date) -> Ok(Param(type_date, False, Some(date_value(date))))
    sql.Time(time) -> {
      let calendar.TimeOfDay(hours:, minutes:, seconds:, nanoseconds:) = time
      Ok(Param(
        type_time,
        False,
        Some(<<
          12,
          0,
          0:little-size(32),
          hours,
          minutes,
          seconds,
          { nanoseconds / 1000 }:little-size(32),
        >>),
      ))
    }
    sql.Array(_) ->
      Error("MySQL has no array type: pass each element as an argument")
  }
}

fn text(s: String) -> Param {
  Param(type_var_string, False, Some(protocol.encode_lenenc_bytes(<<s:utf8>>)))
}

fn date_value(date: calendar.Date) -> BitArray {
  let calendar.Date(year:, month:, day:) = date
  <<4, year:little-size(16), { calendar.month_to_int(month) }, day>>
}

fn datetime(date: calendar.Date, time: calendar.TimeOfDay) -> BitArray {
  let calendar.Date(year:, month:, day:) = date
  let calendar.TimeOfDay(hours:, minutes:, seconds:, nanoseconds:) = time
  <<
    11,
    year:little-size(16),
    { calendar.month_to_int(month) },
    day,
    hours,
    minutes,
    seconds,
    { nanoseconds / 1000 }:little-size(32),
  >>
}

// --- Rows --------------------------------------------------------------------

/// A row of the binary protocol: a 0x00 header, a NULL bitmap offset by
/// two bits, then each non-NULL value in turn.
pub fn decode_row(
  columns: List(Column),
  payload: BitArray,
) -> Result(List(sql.Value), Nil) {
  case payload {
    <<0x00, rest:bits>> -> {
      let count = list.length(columns)
      let bitmap_size = { count + 7 + 2 } / 8
      case rest {
        <<bitmap:bytes-size(bitmap_size), values:bits>> ->
          decode_values(columns, bitmap, 0, values, [])
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn decode_values(
  columns: List(Column),
  bitmap: BitArray,
  index: Int,
  data: BitArray,
  acc: List(sql.Value),
) -> Result(List(sql.Value), Nil) {
  case columns {
    [] -> Ok(list.reverse(acc))
    [column, ..rest] ->
      case protocol.is_null(bitmap, index + 2) {
        True -> decode_values(rest, bitmap, index + 1, data, [sql.Null, ..acc])
        False -> {
          use #(value, data) <- result.try(decode_value(column, data))
          decode_values(rest, bitmap, index + 1, data, [value, ..acc])
        }
      }
  }
}

/// One non-NULL value of `column`'s type, and the bytes after it.
pub fn decode_value(
  column: Column,
  data: BitArray,
) -> Result(#(sql.Value, BitArray), Nil) {
  let unsigned = protocol.has(column.flags, protocol.flag_unsigned)
  case column.type_, data, unsigned {
    // TINYINT(1) is how MySQL spells BOOLEAN.
    1, <<v, rest:bits>>, _ if column.length == 1 -> Ok(#(sql.Bool(v != 0), rest))
    1, <<v, rest:bits>>, True -> Ok(#(sql.Int(v), rest))
    1, <<v:signed-size(8), rest:bits>>, False -> Ok(#(sql.Int(v), rest))
    2, <<v:little-size(16), rest:bits>>, True
    | 13, <<v:little-size(16), rest:bits>>, _
    -> Ok(#(sql.Int(v), rest))
    2, <<v:little-signed-size(16), rest:bits>>, False -> Ok(#(sql.Int(v), rest))
    3, <<v:little-size(32), rest:bits>>, True
    | 9, <<v:little-size(32), rest:bits>>, True
    -> Ok(#(sql.Int(v), rest))
    3, <<v:little-signed-size(32), rest:bits>>, False
    | 9, <<v:little-signed-size(32), rest:bits>>, False
    -> Ok(#(sql.Int(v), rest))
    8, <<v:little-size(64), rest:bits>>, True -> Ok(#(sql.Int(v), rest))
    8, <<v:little-signed-size(64), rest:bits>>, False -> Ok(#(sql.Int(v), rest))
    4, <<v:float-little-size(32), rest:bits>>, _ -> Ok(#(sql.Float(v), rest))
    5, <<v:float-little-size(64), rest:bits>>, _ -> Ok(#(sql.Float(v), rest))
    6, _, _ -> Ok(#(sql.Null, data))
    10, <<size, rest:bits>>, _ -> decode_date(size, rest)
    7, <<size, rest:bits>>, _ | 12, <<size, rest:bits>>, _ ->
      decode_datetime(size, rest)
    11, <<size, rest:bits>>, _ -> decode_time(size, rest)
    0, _, _ | 246, _, _ -> lenenc_text(data)
    _, _, _ -> {
      use #(bytes, rest) <- result.try(lenenc(data))
      case column.charset == protocol.charset_binary {
        True -> Ok(#(sql.Bytes(bytes), rest))
        False ->
          case bit_array.to_string(bytes) {
            Ok(text) -> Ok(#(sql.Text(text), rest))
            Error(Nil) -> Ok(#(sql.Bytes(bytes), rest))
          }
      }
    }
  }
}

fn lenenc(data: BitArray) -> Result(#(BitArray, BitArray), Nil) {
  case protocol.lenenc_bytes(data) {
    Ok(#(Some(bytes), rest)) -> Ok(#(bytes, rest))
    _ -> Error(Nil)
  }
}

fn lenenc_text(data: BitArray) -> Result(#(sql.Value, BitArray), Nil) {
  use #(bytes, rest) <- result.try(lenenc(data))
  use text <- result.map(bit_array.to_string(bytes))
  #(sql.Text(text), rest)
}

fn decode_date(
  size: Int,
  data: BitArray,
) -> Result(#(sql.Value, BitArray), Nil) {
  case size, data {
    0, _ -> Ok(#(sql.Text("0000-00-00"), data))
    4, <<year:little-size(16), month, day, rest:bits>> ->
      Ok(#(date_or_text(year, month, day), rest))
    _, _ -> Error(Nil)
  }
}

fn date_or_text(year: Int, month: Int, day: Int) -> sql.Value {
  case calendar.month_from_int(month) {
    Ok(m) if day >= 1 -> sql.Date(calendar.Date(year:, month: m, day:))
    _ -> sql.Text(date_text(year, month, day))
  }
}

fn decode_datetime(
  size: Int,
  data: BitArray,
) -> Result(#(sql.Value, BitArray), Nil) {
  let parts = case size, data {
    0, _ -> Ok(#(0, 0, 0, 0, 0, 0, 0, data))
    4, <<y:little-size(16), mo, d, rest:bits>> ->
      Ok(#(y, mo, d, 0, 0, 0, 0, rest))
    7, <<y:little-size(16), mo, d, h, mi, s, rest:bits>> ->
      Ok(#(y, mo, d, h, mi, s, 0, rest))
    11, <<y:little-size(16), mo, d, h, mi, s, us:little-size(32), rest:bits>> ->
      Ok(#(y, mo, d, h, mi, s, us, rest))
    _, _ -> Error(Nil)
  }
  use #(y, mo, d, h, mi, s, us, rest) <- result.map(parts)
  let value = case calendar.month_from_int(mo) {
    Ok(month) if d >= 1 ->
      sql.Timestamp(timestamp.from_calendar(
        calendar.Date(year: y, month:, day: d),
        calendar.TimeOfDay(
          hours: h,
          minutes: mi,
          seconds: s,
          nanoseconds: us * 1000,
        ),
        calendar.utc_offset,
      ))
    _ ->
      sql.Text(
        date_text(y, mo, d)
        <> " "
        <> pad(h, 2)
        <> ":"
        <> pad(mi, 2)
        <> ":"
        <> pad(s, 2),
      )
  }
  #(value, rest)
}

/// A `TIME` within a day becomes a time of day. MySQL's `TIME` also holds
/// durations (negative, or past 24 hours), which come back as text.
fn decode_time(
  size: Int,
  data: BitArray,
) -> Result(#(sql.Value, BitArray), Nil) {
  let parts = case size, data {
    0, _ -> Ok(#(0, 0, 0, 0, 0, 0, data))
    8, <<neg, days:little-size(32), h, m, s, rest:bits>> ->
      Ok(#(neg, days, h, m, s, 0, rest))
    12, <<neg, days:little-size(32), h, m, s, us:little-size(32), rest:bits>> ->
      Ok(#(neg, days, h, m, s, us, rest))
    _, _ -> Error(Nil)
  }
  use #(neg, days, h, m, s, us, rest) <- result.map(parts)
  let value = case neg, days {
    0, 0 ->
      sql.Time(calendar.TimeOfDay(
        hours: h,
        minutes: m,
        seconds: s,
        nanoseconds: us * 1000,
      ))
    _, _ -> {
      let sign = case neg {
        0 -> ""
        _ -> "-"
      }
      let fraction = case us {
        0 -> ""
        _ -> "." <> pad(us, 6)
      }
      sql.Text(
        sign
        <> pad(days * 24 + h, 2)
        <> ":"
        <> pad(m, 2)
        <> ":"
        <> pad(s, 2)
        <> fraction,
      )
    }
  }
  #(value, rest)
}

fn date_text(year: Int, month: Int, day: Int) -> String {
  pad(year, 4) <> "-" <> pad(month, 2) <> "-" <> pad(day, 2)
}

fn pad(n: Int, width: Int) -> String {
  string.pad_start(int.to_string(n), width, "0")
}

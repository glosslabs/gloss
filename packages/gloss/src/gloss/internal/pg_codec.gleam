//// Converting between `sql.Value`s and Postgres's text format.
////
//// Arguments are sent as text, except `Bytes`, which is sent as binary, and
//// the server works out each one's type from the statement. Result columns
//// are asked for as text and read according to their type OID. A type this
//// module doesn't know, or a value it can't represent (`NaN`, `infinity`,
//// BC dates), is returned as `Text`, so no column is ever unreadable.
////
//// The connection sets `DateStyle` to `ISO` and `TimeZone` to `UTC`, which
//// fixes the date and time formats parsed here.

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gloss/sql.{type Value}

// --- Arguments ---------------------------------------------------------------

/// The format (0 text, 1 binary) and bytes for an argument, or `None` for
/// NULL.
pub fn encode(value: Value) -> Option(#(Int, BitArray)) {
  case value {
    sql.Null -> None
    sql.Bytes(bytes) -> Some(#(1, bytes))
    _ -> Some(#(0, <<to_text(value):utf8>>))
  }
}

fn to_text(value: Value) -> String {
  case value {
    sql.Null -> "NULL"
    sql.Bool(True) -> "t"
    sql.Bool(False) -> "f"
    sql.Int(i) -> int.to_string(i)
    sql.Float(f) -> float.to_string(f)
    sql.Text(s) -> s
    sql.Bytes(b) -> "\\x" <> string.lowercase(bit_array.base16_encode(b))
    sql.Timestamp(t) -> timestamp.to_rfc3339(t, duration.seconds(0))
    sql.Date(d) -> date_to_text(d)
    sql.Time(t) -> time_to_text(t)
    sql.Array(values) -> array_to_text(values)
  }
}

fn date_to_text(date: calendar.Date) -> String {
  pad(date.year, 4)
  <> "-"
  <> pad(calendar.month_to_int(date.month), 2)
  <> "-"
  <> pad(date.day, 2)
}

fn time_to_text(time: calendar.TimeOfDay) -> String {
  pad(time.hours, 2)
  <> ":"
  <> pad(time.minutes, 2)
  <> ":"
  <> pad(time.seconds, 2)
  <> "."
  <> pad(time.nanoseconds / 1000, 6)
}

fn pad(value: Int, width: Int) -> String {
  string.pad_start(int.to_string(value), width, "0")
}

/// An array literal: `{1,2,NULL}`, with every non-null element quoted.
fn array_to_text(values: List(Value)) -> String {
  let elements =
    list.map(values, fn(value) {
      case value {
        sql.Null -> "NULL"
        sql.Array(inner) -> array_to_text(inner)
        _ -> quote(to_text(value))
      }
    })
  "{" <> string.join(elements, ",") <> "}"
}

fn quote(text: String) -> String {
  let escaped =
    text |> string.replace("\\", "\\\\") |> string.replace("\"", "\\\"")
  "\"" <> escaped <> "\""
}

// --- Columns -----------------------------------------------------------------

/// Read a text-format column of type `oid`.
pub fn decode(oid: Int, raw: BitArray) -> Value {
  case bit_array.to_string(raw) {
    Error(Nil) -> sql.Bytes(raw)
    Ok(text) ->
      case array_element(oid) {
        Ok(element) ->
          parse_array(text)
          |> result.map(fn(items) { array_value(element, items) })
          |> result.unwrap(sql.Text(text))
        Error(Nil) -> decode_scalar(oid, text)
      }
  }
}

fn decode_scalar(oid: Int, text: String) -> Value {
  let value = case oid {
    16 -> parse_bool(text)
    20 | 21 | 23 | 26 -> int.parse(text) |> result.map(sql.Int)
    700 | 701 -> parse_float(text) |> result.map(sql.Float)
    17 -> parse_bytea(text) |> result.map(sql.Bytes)
    1082 -> parse_date(text) |> result.map(sql.Date)
    1083 -> parse_time(text) |> result.map(sql.Time)
    1114 | 1184 -> parse_timestamp(text) |> result.map(sql.Timestamp)
    _ -> Error(Nil)
  }
  result.unwrap(value, sql.Text(text))
}

/// The element type of an array type.
fn array_element(oid: Int) -> Result(Int, Nil) {
  case oid {
    1000 -> Ok(16)
    1001 -> Ok(17)
    1005 -> Ok(21)
    1007 -> Ok(23)
    1016 -> Ok(20)
    1028 -> Ok(26)
    1021 -> Ok(700)
    1022 -> Ok(701)
    1182 -> Ok(1082)
    1183 -> Ok(1083)
    1115 -> Ok(1114)
    1185 -> Ok(1184)
    // text, varchar, bpchar, name, uuid, json, jsonb, numeric
    1009 | 1015 | 1014 | 1003 | 2951 | 199 | 3807 | 1231 -> Ok(25)
    _ -> Error(Nil)
  }
}

fn parse_bool(text: String) -> Result(Value, Nil) {
  case text {
    "t" -> Ok(sql.Bool(True))
    "f" -> Ok(sql.Bool(False))
    _ -> Error(Nil)
  }
}

/// Postgres writes floats in the shortest form that reads back exactly,
/// which may lack a fraction (`3`, `1e+20`); Erlang wants one.
fn parse_float(text: String) -> Result(Float, Nil) {
  use <- result.lazy_or(float.parse(text))
  use <- result.lazy_or(int.parse(text) |> result.map(int.to_float))
  case string.split_once(text, "e") {
    Ok(#(mantissa, exponent)) -> float.parse(mantissa <> ".0e" <> exponent)
    Error(Nil) -> Error(Nil)
  }
}

fn parse_bytea(text: String) -> Result(BitArray, Nil) {
  case text {
    "\\x" <> hex -> bit_array.base16_decode(hex)
    _ -> Error(Nil)
  }
}

/// `2024-01-02`
fn parse_date(text: String) -> Result(calendar.Date, Nil) {
  case string.split(text, "-") {
    [year, month, day] -> {
      use year <- result.try(digits(year))
      use month <- result.try(
        digits(month) |> result.try(calendar.month_from_int),
      )
      use day <- result.try(digits(day))
      let date = calendar.Date(year:, month:, day:)
      case calendar.is_valid_date(date) {
        True -> Ok(date)
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// `03:04:05` or `03:04:05.123456`
fn parse_time(text: String) -> Result(calendar.TimeOfDay, Nil) {
  let #(whole, fraction) = case string.split_once(text, ".") {
    Ok(#(whole, fraction)) -> #(whole, fraction)
    Error(Nil) -> #(text, "")
  }
  case string.split(whole, ":") {
    [hours, minutes, seconds] -> {
      use hours <- result.try(digits(hours))
      use minutes <- result.try(digits(minutes))
      use seconds <- result.try(digits(seconds))
      use nanoseconds <- result.try(case fraction {
        "" -> Ok(0)
        _ ->
          case string.length(fraction) <= 9 {
            True -> digits(string.pad_end(fraction, 9, "0"))
            False -> Error(Nil)
          }
      })
      Ok(calendar.TimeOfDay(hours:, minutes:, seconds:, nanoseconds:))
    }
    _ -> Error(Nil)
  }
}

/// `2024-01-02 03:04:05.123456` with an optional UTC offset: `+00`,
/// `-05:30` or `+05:30:15`. Without one the time is taken as UTC.
fn parse_timestamp(text: String) -> Result(timestamp.Timestamp, Nil) {
  use #(date, time) <- result.try(string.split_once(text, " "))
  use date <- result.try(parse_date(date))
  let #(time, offset) = split_offset(time)
  use time <- result.try(parse_time(time))
  use offset <- result.try(parse_offset(offset))
  Ok(timestamp.from_calendar(date, time, offset))
}

fn split_offset(time: String) -> #(String, String) {
  case string.split_once(time, "+") {
    Ok(#(time, offset)) -> #(time, "+" <> offset)
    Error(Nil) ->
      case string.split_once(time, "-") {
        Ok(#(time, offset)) -> #(time, "-" <> offset)
        Error(Nil) -> #(time, "")
      }
  }
}

fn parse_offset(offset: String) -> Result(duration.Duration, Nil) {
  case offset {
    "" -> Ok(duration.seconds(0))
    "+" <> rest -> offset_seconds(rest) |> result.map(duration.seconds)
    "-" <> rest ->
      offset_seconds(rest) |> result.map(fn(s) { duration.seconds(-s) })
    _ -> Error(Nil)
  }
}

fn offset_seconds(text: String) -> Result(Int, Nil) {
  case list.try_map(string.split(text, ":"), digits) {
    Ok([hours]) -> Ok(hours * 3600)
    Ok([hours, minutes]) -> Ok(hours * 3600 + minutes * 60)
    Ok([hours, minutes, seconds]) -> Ok(hours * 3600 + minutes * 60 + seconds)
    _ -> Error(Nil)
  }
}

/// Only ASCII digits: `int.parse` would also take a sign.
fn digits(text: String) -> Result(Int, Nil) {
  case text != "" && string.to_graphemes(text) |> list.all(is_digit) {
    True -> int.parse(text)
    False -> Error(Nil)
  }
}

fn is_digit(grapheme: String) -> Bool {
  case grapheme {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

// --- Arrays ------------------------------------------------------------------

pub type Item {
  Item(Option(String))
  Nested(List(Item))
}

fn array_value(element: Int, items: List(Item)) -> Value {
  sql.Array(
    list.map(items, fn(item) {
      case item {
        Item(None) -> sql.Null
        Item(Some(text)) -> decode_scalar(element, text)
        Nested(items) -> array_value(element, items)
      }
    }),
  )
}

/// Parse an array literal such as `{1,"a b",NULL,{2,3}}`. A leading
/// dimension decoration (`[0:1]=`) is skipped.
pub fn parse_array(text: String) -> Result(List(Item), Nil) {
  let text = case text {
    "[" <> _ ->
      case string.split_once(text, "=") {
        Ok(#(_, literal)) -> literal
        Error(Nil) -> text
      }
    _ -> text
  }
  case text {
    "{" <> rest ->
      case items(rest, []) {
        Ok(#(items, "")) -> Ok(items)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// The items up to and including the closing brace, and what follows it.
fn items(text: String, acc: List(Item)) -> Result(#(List(Item), String), Nil) {
  case text {
    "}" <> rest -> Ok(#(list.reverse(acc), rest))
    _ -> {
      use #(item, rest) <- result.try(item(text))
      let acc = [item, ..acc]
      case rest {
        "," <> rest -> items(rest, acc)
        "}" <> rest -> Ok(#(list.reverse(acc), rest))
        _ -> Error(Nil)
      }
    }
  }
}

fn item(text: String) -> Result(#(Item, String), Nil) {
  case text {
    "{" <> rest -> {
      use #(inner, rest) <- result.try(items(rest, []))
      Ok(#(Nested(inner), rest))
    }
    "\"" <> rest -> {
      use #(value, rest) <- result.try(quoted(rest, ""))
      Ok(#(Item(Some(value)), rest))
    }
    _ -> {
      let #(value, rest) = unquoted(text, "")
      case string.uppercase(value) {
        "NULL" -> Ok(#(Item(None), rest))
        "" -> Error(Nil)
        _ -> Ok(#(Item(Some(value)), rest))
      }
    }
  }
}

fn quoted(text: String, acc: String) -> Result(#(String, String), Nil) {
  case string.pop_grapheme(text) {
    Ok(#("\"", rest)) -> Ok(#(acc, rest))
    Ok(#("\\", rest)) ->
      case string.pop_grapheme(rest) {
        Ok(#(escaped, rest)) -> quoted(rest, acc <> escaped)
        Error(Nil) -> Error(Nil)
      }
    Ok(#(grapheme, rest)) -> quoted(rest, acc <> grapheme)
    Error(Nil) -> Error(Nil)
  }
}

fn unquoted(text: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(text) {
    Ok(#(",", _)) | Ok(#("}", _)) | Error(Nil) -> #(acc, text)
    Ok(#(grapheme, rest)) -> unquoted(rest, acc <> grapheme)
  }
}

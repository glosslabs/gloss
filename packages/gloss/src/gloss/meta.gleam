//// Structured metadata: the `key=value` pairs that `gloss/tracer` attaches
//// to events and `gloss/logger` attaches to entries.
////
//// ```gleam
//// [#("transfer", meta.String("t-17")), #("count", meta.Int(3))]
//// ```

import gleam/float
import gleam/int
import gleam/list
import gleam/string

pub type Value {
  String(String)
  Int(Int)
  Float(Float)
  Bool(Bool)
}

pub type Meta =
  List(#(String, Value))

/// The first value stored under `key`.
pub fn get(meta: Meta, key: String) -> Result(Value, Nil) {
  list.key_find(meta, key)
}

/// The bare text of a value: strings unchanged, numbers as Gleam prints
/// them, booleans as `true` and `false`.
pub fn to_string(value: Value) -> String {
  case value {
    String(s) -> s
    Int(i) -> int.to_string(i)
    Float(f) -> float.to_string(f)
    Bool(True) -> "true"
    Bool(False) -> "false"
  }
}

/// One line of space-separated `key=value` pairs, in order. Strings are
/// double-quoted with `\`, `"` and newlines escaped; other values are bare.
/// Empty metadata formats as the empty string.
///
/// ```gleam
/// meta.format([#("transfer", meta.String("t-17")), #("count", meta.Int(3))])
/// // -> "transfer=\"t-17\" count=3"
/// ```
pub fn format(meta: Meta) -> String {
  meta
  |> list.map(fn(entry) { entry.0 <> "=" <> render(entry.1) })
  |> string.join(" ")
}

fn render(value: Value) -> String {
  case value {
    String(s) -> quote(s)
    other -> to_string(other)
  }
}

fn quote(s: String) -> String {
  let escaped =
    s
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
  "\"" <> escaped <> "\""
}

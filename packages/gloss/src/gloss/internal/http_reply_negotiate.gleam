//// Choosing a media type from an `Accept` header.

import gleam/float
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string

type Range {
  Range(type_: String, subtype: String, q: Float)
}

/// The offered media type the client prefers, by the quality of the most
/// specific range that matches each one. Ties go to the earlier offer.
/// Without an `Accept` header every offer is acceptable, so the first one
/// wins. `Error(Nil)` when the client accepts none of them.
pub fn choose(
  accept: Result(String, Nil),
  offered: List(String),
) -> Result(String, Nil) {
  case accept {
    Error(Nil) -> list.first(offered)
    Ok(header) -> {
      let ranges = parse(header)
      offered
      |> list.index_map(fn(offer, index) {
        #(offer, quality(ranges, offer), index)
      })
      |> list.filter(fn(scored) { scored.1 >. 0.0 })
      |> list.sort(fn(a, b) {
        case float.compare(b.1, a.1) {
          order.Eq -> int.compare(a.2, b.2)
          other -> other
        }
      })
      |> list.first
      |> result.map(fn(scored) { scored.0 })
    }
  }
}

fn quality(ranges: List(Range), offer: String) -> Float {
  let #(type_, subtype) = split_type(offer)
  let matches =
    list.filter_map(ranges, fn(range) {
      case range.type_, range.subtype {
        t, s if t == type_ && s == subtype -> Ok(#(2, range.q))
        t, "*" if t == type_ -> Ok(#(1, range.q))
        "*", "*" -> Ok(#(0, range.q))
        _, _ -> Error(Nil)
      }
    })
  // The most specific matching range decides.
  matches
  |> list.sort(fn(a, b) { int.compare(b.0, a.0) })
  |> list.first
  |> result.map(fn(match) { match.1 })
  |> result.unwrap(0.0)
}

fn parse(header: String) -> List(Range) {
  header
  |> string.split(",")
  |> list.filter_map(fn(part) {
    case string.split(part, ";") {
      [media, ..params] -> {
        let #(type_, subtype) = split_type(media)
        case type_, subtype {
          "", _ | _, "" -> Error(Nil)
          _, _ -> Ok(Range(type_:, subtype:, q: q(params)))
        }
      }
      [] -> Error(Nil)
    }
  })
}

fn split_type(media: String) -> #(String, String) {
  case string.split_once(string.lowercase(string.trim(media)), "/") {
    Ok(#(type_, subtype)) -> #(string.trim(type_), string.trim(subtype))
    Error(Nil) -> #("", "")
  }
}

fn q(params: List(String)) -> Float {
  list.find_map(params, fn(param) {
    case string.split_once(string.trim(param), "=") {
      Ok(#(key, value)) if key == "q" || key == "Q" ->
        parse_q(string.trim(value))
      _ -> Error(Nil)
    }
  })
  |> result.unwrap(1.0)
}

fn parse_q(value: String) -> Result(Float, Nil) {
  case float.parse(value), int.parse(value) {
    Ok(q), _ -> Ok(q)
    _, Ok(q) -> Ok(int.to_float(q))
    _, _ -> Error(Nil)
  }
}

/// Whether an `accept-encoding` header allows `coding` (e.g. `"gzip"`),
/// by its own quality or else that of `*`. No header means only `identity`.
pub fn accepts_encoding(header: Result(String, Nil), coding: String) -> Bool {
  case header {
    Error(Nil) -> False
    Ok(header) -> {
      let codings =
        header
        |> string.split(",")
        |> list.filter_map(fn(part) {
          case string.split(part, ";") {
            [name, ..params] ->
              case string.lowercase(string.trim(name)) {
                "" -> Error(Nil)
                name -> Ok(#(name, q(params)))
              }
            [] -> Error(Nil)
          }
        })
      case list.key_find(codings, coding), list.key_find(codings, "*") {
        Ok(q), _ -> q >. 0.0
        Error(Nil), Ok(q) -> q >. 0.0
        Error(Nil), Error(Nil) -> False
      }
    }
  }
}

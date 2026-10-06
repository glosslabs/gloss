//// The segment trie behind `gloss/http/router`: insertion and lookup only.
////
//// Lookup prefers static segments over `:params` over a trailing `*rest`,
//// and backtracks: a request that matches a static branch's path but not
//// its method can still be served by a param branch with that method.

import gleam/dict.{type Dict}
import gleam/http.{type Method}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri

pub type Segment {
  Static(String)
  Param(String)
  Wildcard(String)
}

pub opaque type Trie(a) {
  Node(
    methods: Dict(Method, Entry(a)),
    static: Dict(String, Trie(a)),
    param: Option(Trie(a)),
    wildcard: Dict(Method, Entry(a)),
  )
}

/// A route's value and the names of its params and wildcard, in path order.
type Entry(a) {
  Entry(names: List(String), value: a)
}

pub type Lookup(a) {
  Found(value: a, params: List(#(String, String)))
  /// The path exists, but not for this method. `allowed` is sorted.
  NotAllowed(allowed: List(Method))
  Missing
}

pub fn new() -> Trie(a) {
  Node(
    methods: dict.new(),
    static: dict.new(),
    param: None,
    wildcard: dict.new(),
  )
}

/// The non-empty segments of a path: `"/a//b/"` is `["a", "b"]`.
pub fn split(path: String) -> List(String) {
  string.split(path, "/") |> list.filter(fn(s) { s != "" })
}

/// Parse a route template. `:name` is a param and `*name` a wildcard that
/// must come last.
pub fn parse(template: String) -> Result(List(Segment), String) {
  parse_segments(split(template), [])
}

fn parse_segments(
  parts: List(String),
  acc: List(Segment),
) -> Result(List(Segment), String) {
  case parts {
    [] -> Ok(list.reverse(acc))
    [":", ..] -> Error("a param needs a name after ':'")
    ["*", ..] -> Error("a wildcard needs a name after '*'")
    [":" <> name, ..rest] -> parse_segments(rest, [Param(name), ..acc])
    ["*" <> name] -> Ok(list.reverse([Wildcard(name), ..acc]))
    ["*" <> _, ..] -> Error("a wildcard must be the last segment")
    [part, ..rest] -> parse_segments(rest, [Static(part), ..acc])
  }
}

/// The template written back out in canonical form, e.g. `"/notes/:id"`.
pub fn to_template(segments: List(Segment)) -> String {
  "/"
  <> {
    segments
    |> list.map(fn(segment) {
      case segment {
        Static(s) -> s
        Param(name) -> ":" <> name
        Wildcard(name) -> "*" <> name
      }
    })
    |> string.join("/")
  }
}

/// Add a route. Fails when the same method is already registered for an
/// equivalent template (param names do not distinguish templates).
pub fn insert(
  trie: Trie(a),
  method: Method,
  segments: List(Segment),
  value: a,
) -> Result(Trie(a), Nil) {
  let names =
    list.filter_map(segments, fn(segment) {
      case segment {
        Static(_) -> Error(Nil)
        Param(name) | Wildcard(name) -> Ok(name)
      }
    })
  insert_at(trie, method, segments, Entry(names:, value:))
}

fn insert_at(
  node: Trie(a),
  method: Method,
  segments: List(Segment),
  entry: Entry(a),
) -> Result(Trie(a), Nil) {
  case segments {
    [] -> {
      use methods <- add_method(node.methods, method, entry)
      Ok(Node(..node, methods:))
    }
    [Wildcard(_)] -> {
      use wildcard <- add_method(node.wildcard, method, entry)
      Ok(Node(..node, wildcard:))
    }
    [Wildcard(_), ..] -> Error(Nil)
    [Static(s), ..rest] -> {
      let child = dict.get(node.static, s) |> option.from_result
      let child = option.unwrap(child, new())
      case insert_at(child, method, rest, entry) {
        Ok(child) ->
          Ok(Node(..node, static: dict.insert(node.static, s, child)))
        Error(Nil) -> Error(Nil)
      }
    }
    [Param(_), ..rest] -> {
      let child = option.unwrap(node.param, new())
      case insert_at(child, method, rest, entry) {
        Ok(child) -> Ok(Node(..node, param: Some(child)))
        Error(Nil) -> Error(Nil)
      }
    }
  }
}

fn add_method(
  methods: Dict(Method, Entry(a)),
  method: Method,
  entry: Entry(a),
  next: fn(Dict(Method, Entry(a))) -> Result(Trie(a), Nil),
) -> Result(Trie(a), Nil) {
  case dict.has_key(methods, method) {
    True -> Error(Nil)
    False -> next(dict.insert(methods, method, entry))
  }
}

/// Find the route for a method and the raw (not yet decoded) path
/// segments. `HEAD` falls back to `GET`.
pub fn lookup(
  trie: Trie(a),
  method: Method,
  segments: List(String),
) -> Lookup(a) {
  let candidates = candidates(trie, segments, [])
  case find(candidates, method) {
    Ok(found) -> found
    Error(Nil) ->
      case method, find(candidates, http.Get) {
        http.Head, Ok(found) -> found
        _, _ ->
          case candidates {
            [] -> Missing
            _ -> NotAllowed(allowed(candidates))
          }
      }
  }
}

/// Every node whose path matches, best first, with the raw values captured
/// on the way there in path order.
fn candidates(
  node: Trie(a),
  segments: List(String),
  captured: List(String),
) -> List(#(Dict(Method, Entry(a)), List(String))) {
  case segments {
    [] ->
      case dict.is_empty(node.methods) {
        True -> []
        False -> [#(node.methods, list.reverse(captured))]
      }
    [segment, ..rest] -> {
      let static = case dict.get(node.static, segment) {
        Ok(child) -> candidates(child, rest, captured)
        Error(Nil) -> []
      }
      let param = case node.param {
        Some(child) -> candidates(child, rest, [decode(segment), ..captured])
        None -> []
      }
      let wildcard = case dict.is_empty(node.wildcard) {
        True -> []
        False -> {
          let rest = segments |> list.map(decode) |> string.join("/")
          [#(node.wildcard, list.reverse([rest, ..captured]))]
        }
      }
      list.flatten([static, param, wildcard])
    }
  }
}

fn find(
  candidates: List(#(Dict(Method, Entry(a)), List(String))),
  method: Method,
) -> Result(Lookup(a), Nil) {
  list.find_map(candidates, fn(candidate) {
    let #(methods, values) = candidate
    case dict.get(methods, method) {
      Ok(Entry(names:, value:)) ->
        Ok(Found(value:, params: list.zip(names, values)))
      Error(Nil) -> Error(Nil)
    }
  })
}

fn allowed(
  candidates: List(#(Dict(Method, Entry(a)), List(String))),
) -> List(Method) {
  let methods =
    candidates
    |> list.flat_map(fn(candidate) { dict.keys(candidate.0) })
  let methods = case list.contains(methods, http.Get) {
    True -> [http.Head, ..methods]
    False -> methods
  }
  methods
  |> list.unique
  |> list.sort(fn(a, b) {
    string.compare(http.method_to_string(a), http.method_to_string(b))
  })
}

fn decode(segment: String) -> String {
  case uri.percent_decode(segment) {
    Ok(decoded) -> decoded
    Error(Nil) -> segment
  }
}

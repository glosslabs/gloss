//// Building and reading URLs and query strings, on the BEAM and in
//// JavaScript. It sits on `gleam/uri` and adds what building URLs needs:
//// path segments and query parameters that are encoded for you, strict
//// RFC 3986 encoding, and the user, password and parameters of connection
//// URLs, decoded.
////
//// ```gleam
//// let assert Ok(api) = url.parse("https://api.example.com/v1")
//// api
//// |> url.segments(["users", "42", "posts"])
//// |> url.query("tag", "a&b")
//// |> url.to_string
//// // -> "https://api.example.com/v1/users/42/posts?tag=a%26b"
////
//// let assert Ok(db) = url.parse("postgres://ada:p%40ss@db:5432/app?sslmode=require")
//// url.password(db)       // -> Some("p@ss")
//// url.path_segments(db)  // -> ["app"]
//// url.params(db)         // -> [#("sslmode", "require")]
//// ```
////
//// Everything this module writes is encoded strictly: every byte but the
//// unreserved `A-Z a-z 0-9 - _ . ~` becomes `%XX`, which every server and
//// signature scheme (S3's, OAuth's) agrees on.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}

/// A URL. Its query is kept as decoded parameters, so adding one never
/// disturbs the others.
pub opaque type Url {
  Url(uri: Uri, params: List(#(String, String)))
}

/// Read a URL. `Error(Nil)` when it isn't one, or its query string is
/// malformed.
pub fn parse(text: String) -> Result(Url, Nil) {
  use parsed <- result.try(uri.parse(text))
  from_uri(parsed)
}

/// A URL from a `gleam/uri` value.
pub fn from_uri(value: Uri) -> Result(Url, Nil) {
  use params <- result.map(case value.query {
    None | Some("") -> Ok([])
    Some(query) -> parse_query(query)
  })
  Url(uri: uri.Uri(..value, query: None), params:)
}

/// The URL as a `gleam/uri` value, e.g. for `request.from_uri`.
pub fn to_uri(url: Url) -> Uri {
  case url.params {
    [] -> url.uri
    params -> uri.Uri(..url.uri, query: Some(query_string(params)))
  }
}

pub fn to_string(url: Url) -> String {
  uri.to_string(to_uri(url))
}

// --- Building -----------------------------------------------------------------

/// Add a path segment, encoded, so `/`, `?` and `#` in it can't change the
/// URL's shape.
pub fn segment(url: Url, segment: String) -> Url {
  let path = case string.ends_with(url.uri.path, "/") {
    True -> url.uri.path <> encode(segment)
    False -> url.uri.path <> "/" <> encode(segment)
  }
  Url(..url, uri: uri.Uri(..url.uri, path:))
}

/// Add path segments, each encoded.
pub fn segments(url: Url, segments: List(String)) -> Url {
  list.fold(segments, url, segment)
}

/// Add a query parameter, after any already there.
pub fn query(url: Url, key: String, value: String) -> Url {
  Url(..url, params: list.append(url.params, [#(key, value)]))
}

/// Set a query parameter, replacing every one already there by that name.
pub fn set_query(url: Url, key: String, value: String) -> Url {
  let others = list.filter(url.params, fn(param) { param.0 != key })
  Url(..url, params: list.append(others, [#(key, value)]))
}

/// Drop the query parameters named `key`.
pub fn delete_query(url: Url, key: String) -> Url {
  Url(..url, params: list.filter(url.params, fn(param) { param.0 != key }))
}

/// Replace the fragment (`#...`), or remove it with `None`.
pub fn set_fragment(url: Url, fragment: Option(String)) -> Url {
  Url(..url, uri: uri.Uri(..url.uri, fragment:))
}

// --- Reading ------------------------------------------------------------------

pub fn scheme(url: Url) -> Option(String) {
  url.uri.scheme
}

pub fn host(url: Url) -> Option(String) {
  url.uri.host
}

pub fn port(url: Url) -> Option(Int) {
  url.uri.port
}

/// The path as written, still encoded.
pub fn path(url: Url) -> String {
  url.uri.path
}

/// The path's segments, decoded, without empty ones:
/// `/a/b%20c/` is `["a", "b c"]`. A segment that doesn't decode is kept as
/// written.
pub fn path_segments(url: Url) -> List(String) {
  url.uri.path
  |> string.split("/")
  |> list.filter(fn(segment) { segment != "" })
  |> list.map(fn(segment) { decode(segment) |> result.unwrap(segment) })
}

/// The query parameters, decoded, in order.
pub fn params(url: Url) -> List(#(String, String)) {
  url.params
}

/// The first query parameter named `key`.
pub fn param(url: Url, key: String) -> Result(String, Nil) {
  list.key_find(url.params, key)
}

/// The user name from `user:password@`, decoded.
pub fn username(url: Url) -> Option(String) {
  case url.uri.userinfo {
    None -> None
    Some(info) -> {
      let user = case string.split_once(info, ":") {
        Ok(#(user, _)) -> user
        Error(Nil) -> info
      }
      case user {
        "" -> None
        user -> Some(decode(user) |> result.unwrap(user))
      }
    }
  }
}

/// The password from `user:password@`, decoded.
pub fn password(url: Url) -> Option(String) {
  case url.uri.userinfo {
    None -> None
    Some(info) ->
      case string.split_once(info, ":") {
        Ok(#(_, password)) -> Some(decode(password) |> result.unwrap(password))
        Error(Nil) -> None
      }
  }
}

/// The fragment (`#...`), if there is one.
pub fn fragment(url: Url) -> Option(String) {
  url.uri.fragment
}

// --- Encoding -----------------------------------------------------------------

/// Percent-encode everything but the unreserved characters
/// `A-Z a-z 0-9 - _ . ~` (RFC 3986), as UTF-8.
pub fn encode(text: String) -> String {
  encode_bytes(<<text:utf8>>, [])
}

fn encode_bytes(bytes: BitArray, acc: List(String)) -> String {
  case bytes {
    <<>> -> string.concat(list.reverse(acc))
    <<byte, rest:bytes>> ->
      encode_bytes(rest, [
        case unreserved(byte) {
          True -> byte_to_string(byte)
          False -> "%" <> hex(byte)
        },
        ..acc
      ])
    _ -> string.concat(list.reverse(acc))
  }
}

fn unreserved(byte: Int) -> Bool {
  { byte >= 0x41 && byte <= 0x5A }
  || { byte >= 0x61 && byte <= 0x7A }
  || { byte >= 0x30 && byte <= 0x39 }
  || byte == 0x2D
  || byte == 0x5F
  || byte == 0x2E
  || byte == 0x7E
}

fn byte_to_string(byte: Int) -> String {
  let assert Ok(text) = bit_array.to_string(<<byte>>)
  text
}

fn hex(byte: Int) -> String {
  string.pad_start(string.uppercase(int.to_base16(byte)), 2, "0")
}

/// Decode `%XX` escapes. `Error(Nil)` when an escape is malformed or the
/// result isn't UTF-8.
pub fn decode(text: String) -> Result(String, Nil) {
  uri.percent_decode(text)
}

/// `key=value` pairs, each part encoded, joined with `&`, in order.
pub fn query_string(params: List(#(String, String))) -> String {
  params
  |> list.map(fn(param) { encode(param.0) <> "=" <> encode(param.1) })
  |> string.join("&")
}

/// The decoded pairs of a query string. `+` is read as a space, as forms
/// send it.
pub fn parse_query(query: String) -> Result(List(#(String, String)), Nil) {
  uri.parse_query(query)
}

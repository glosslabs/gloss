//// The HTTP/1.1 rules the connection process follows, with no IO: turning
//// parsed request lines and headers into a `Request`, deciding how much
//// body to read and whether to keep the connection open, and encoding
//// responses.

import gleam/bytes_tree.{type BytesTree}
import gleam/http.{type Method}
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gloss/http/reply.{type Request, type RequestBody}
import gloss/internal/http_status as status

/// A request line and its headers, before the body is read.
pub type Head {
  Head(
    method: Method,
    target: String,
    version: #(Int, Int),
    /// Lowercase names, in the order received.
    headers: List(#(String, String)),
  )
}

/// How a request's body is delimited.
pub type BodyFraming {
  /// Exactly this many bytes follow the head.
  Length(Int)
  /// `Transfer-Encoding: chunked`.
  Chunked
}

pub type BodyError {
  /// A transfer coding other than `chunked`, e.g. `gzip`.
  UnsupportedTransferEncoding
  InvalidContentLength
  /// Both `Transfer-Encoding` and `Content-Length`: rejected, because
  /// proxies may disagree about which wins (request smuggling).
  ConflictingFraming
}

/// How a response's body is delimited on the wire.
pub type ResponseFraming {
  ContentLength(Int)
  ChunkedResponse
  /// HTTP/1.0 streams: no framing header, and the connection closes after.
  UntilClose
  /// `101 Switching Protocols`: no body, and the response's own
  /// `connection` header is kept.
  Switching
}

pub fn method(name: String) -> Method {
  case http.parse_method(name) {
    Ok(method) -> method
    Error(Nil) -> http.Other(name)
  }
}

/// How the request's body is delimited: `Length(0)` when there is no
/// body. Repeated identical `Content-Length` values are accepted.
pub fn body_framing(head: Head) -> Result(BodyFraming, BodyError) {
  let lengths = header_values(head, "content-length") |> list.unique
  let codings =
    header_values(head, "transfer-encoding")
    |> list.flat_map(string.split(_, ","))
    |> list.map(fn(coding) { string.lowercase(string.trim(coding)) })
    |> list.filter(fn(coding) { coding != "" })
  case codings, lengths {
    [], [] -> Ok(Length(0))
    [], [value] ->
      case int.parse(string.trim(value)) {
        Ok(n) if n >= 0 -> Ok(Length(n))
        _ -> Error(InvalidContentLength)
      }
    [], _ -> Error(InvalidContentLength)
    _, [_, ..] -> Error(ConflictingFraming)
    ["chunked"], [] -> Ok(Chunked)
    _, [] -> Error(UnsupportedTransferEncoding)
  }
}

/// The size from a chunk-size line (without its CRLF), ignoring chunk
/// extensions: `"1a;name=value"` is 26.
pub fn chunk_size(line: String) -> Result(Int, Nil) {
  let hex = case string.split_once(line, ";") {
    Ok(#(hex, _)) -> hex
    Error(Nil) -> line
  }
  let hex = string.trim(hex)
  case hex != "" && string.length(hex) <= 15 {
    True ->
      case int.base_parse(hex, 16) {
        Ok(n) if n >= 0 -> Ok(n)
        _ -> Error(Nil)
      }
    False -> Error(Nil)
  }
}

/// One chunk of a chunked response. Empty data must not be sent this way:
/// a zero-size chunk ends the body.
pub fn chunk(data: BytesTree) -> BytesTree {
  bytes_tree.from_string(
    int.to_base16(bytes_tree.byte_size(data)) |> string.lowercase,
  )
  |> bytes_tree.append_string("\r\n")
  |> bytes_tree.append_tree(data)
  |> bytes_tree.append_string("\r\n")
}

/// Ends a chunked response, with no trailers.
pub const last_chunk = "0\r\n\r\n"

/// A request the server must refuse whatever the route.
pub type HeadError {
  /// HTTP/1.1 requires exactly one `Host` header; HTTP/1.0 allows none.
  MissingHost
  MultipleHosts
  /// An `Expect` other than `100-continue`, answered `417`.
  UnknownExpectation(String)
}

/// Check the parts of the head every HTTP/1.1 server must enforce.
pub fn check(head: Head) -> Result(Nil, HeadError) {
  case header_values(head, "host"), head.version {
    [], #(1, 1) -> Error(MissingHost)
    [_, _, ..], _ -> Error(MultipleHosts)
    _, _ ->
      case header_values(head, "expect") {
        [] -> Ok(Nil)
        [value] ->
          case string.lowercase(string.trim(value)) {
            "100-continue" -> Ok(Nil)
            _ -> Error(UnknownExpectation(value))
          }
        values -> Error(UnknownExpectation(string.join(values, ", ")))
      }
  }
}

/// Whether the client wants a `100 Continue` before sending the body.
/// HTTP/1.0 clients can't ask for one.
pub fn expects_continue(head: Head) -> Bool {
  head.version == #(1, 1)
  && case list.key_find(head.headers, "expect") {
    Ok(value) -> string.lowercase(string.trim(value)) == "100-continue"
    Error(Nil) -> False
  }
}

/// HTTP/1.1 keeps the connection open unless `Connection: close`;
/// HTTP/1.0 closes it unless `Connection: keep-alive`.
pub fn keep_alive(head: Head) -> Bool {
  let tokens =
    header_values(head, "connection")
    |> list.flat_map(string.split(_, ","))
    |> list.map(fn(token) { string.lowercase(string.trim(token)) })
  case head.version {
    #(1, 1) -> !list.contains(tokens, "close")
    _ -> list.contains(tokens, "keep-alive")
  }
}

/// The request for a head and its body. The host and port come from the
/// `Host` header; the scheme is always `http`.
pub fn to_request(head: Head, body: RequestBody) -> Request {
  let #(path, query) = case string.split_once(head.target, "?") {
    Ok(#(path, query)) -> #(path, Some(query))
    Error(Nil) -> #(head.target, None)
  }
  let #(host, port) = host_and_port(list.key_find(head.headers, "host"))
  request.Request(
    method: head.method,
    headers: head.headers,
    body:,
    scheme: http.Http,
    host:,
    port:,
    path:,
    query:,
  )
}

fn host_and_port(header: Result(String, Nil)) -> #(String, Option(Int)) {
  case header {
    Error(Nil) -> #("", None)
    Ok(value) ->
      case string.split_once(value, ":") {
        Ok(#(host, port)) ->
          case int.parse(port) {
            Ok(port) -> #(host, Some(port))
            Error(Nil) -> #(value, None)
          }
        Error(Nil) -> #(value, None)
      }
  }
}

/// The response as bytes on the wire. Sets `content-length`, `date` and
/// `connection`, replacing any the handler set. For a `HEAD` request the
/// body is left out but `content-length` still describes it.
pub fn encode(
  response: Response(BytesTree),
  keep_alive keep_alive: Bool,
  head_request head_request: Bool,
  date date: String,
) -> BytesTree {
  let head =
    head(
      response,
      framing: ContentLength(bytes_tree.byte_size(response.body)),
      keep_alive:,
      date:,
    )
  case head_request {
    True -> head
    False -> bytes_tree.append_tree(head, response.body)
  }
}

/// The status line and headers for a body sent separately.
pub fn head(
  response: Response(a),
  framing framing: ResponseFraming,
  keep_alive keep_alive: Bool,
  date date: String,
) -> BytesTree {
  let replaced = case framing {
    Switching -> ["content-length", "transfer-encoding", "date"]
    _ -> ["content-length", "transfer-encoding", "date", "connection"]
  }
  let headers =
    response.headers
    |> list.filter(fn(header) { !list.contains(replaced, header.0) })
  let framing_headers = case framing {
    ContentLength(length) -> [#("content-length", int.to_string(length))]
    ChunkedResponse -> [#("transfer-encoding", "chunked")]
    UntilClose | Switching -> []
  }
  let connection = case framing, keep_alive {
    Switching, _ -> []
    _, True -> [#("connection", "keep-alive")]
    _, False -> [#("connection", "close")]
  }
  let headers =
    list.flatten([framing_headers, [#("date", date)], connection, headers])
  list.fold(
    headers,
    bytes_tree.from_string(status_line(response.status)),
    fn(tree, header) {
      bytes_tree.append_string(tree, header.0 <> ": " <> header.1 <> "\r\n")
    },
  )
  |> bytes_tree.append_string("\r\n")
}

pub const continue = "HTTP/1.1 100 Continue\r\n\r\n"

fn status_line(code: Int) -> String {
  "HTTP/1.1 " <> int.to_string(code) <> " " <> status.reason(code) <> "\r\n"
}

fn header_values(head: Head, name: String) -> List(String) {
  list.filter_map(head.headers, fn(header) {
    case header.0 == name {
      True -> Ok(header.1)
      False -> Error(Nil)
    }
  })
}

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
import gloss/http/reply.{type Request}
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

pub type BodyError {
  /// `Transfer-Encoding` is set; only `Content-Length` bodies are read.
  UnsupportedTransferEncoding
  InvalidContentLength
}

pub fn method(name: String) -> Method {
  case http.parse_method(name) {
    Ok(method) -> method
    Error(Nil) -> http.Other(name)
  }
}

/// How many body bytes follow the head: `0` when there is no
/// `Content-Length`. Repeated identical values are accepted.
pub fn content_length(head: Head) -> Result(Int, BodyError) {
  case list.key_find(head.headers, "transfer-encoding") {
    Ok(_) -> Error(UnsupportedTransferEncoding)
    Error(Nil) ->
      case header_values(head, "content-length") |> list.unique {
        [] -> Ok(0)
        [value] ->
          case int.parse(string.trim(value)) {
            Ok(n) if n >= 0 -> Ok(n)
            _ -> Error(InvalidContentLength)
          }
        _ -> Error(InvalidContentLength)
      }
  }
}

/// Whether the client wants a `100 Continue` before sending the body.
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
pub fn to_request(head: Head, body: BitArray) -> Request {
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
  let length = bytes_tree.byte_size(response.body)
  let headers =
    response.headers
    |> list.filter(fn(header) {
      !list.contains(["content-length", "date", "connection"], header.0)
    })
  let headers = [
    #("content-length", int.to_string(length)),
    #("date", date),
    #("connection", case keep_alive {
      True -> "keep-alive"
      False -> "close"
    }),
    ..headers
  ]
  let head =
    list.fold(
      headers,
      bytes_tree.from_string(status_line(response.status)),
      fn(tree, header) {
        bytes_tree.append_string(tree, header.0 <> ": " <> header.1 <> "\r\n")
      },
    )
    |> bytes_tree.append_string("\r\n")
  case head_request {
    True -> head
    False -> bytes_tree.append_tree(head, response.body)
  }
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

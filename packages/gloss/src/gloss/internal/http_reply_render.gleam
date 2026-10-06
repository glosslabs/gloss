//// Turning a `reply.Response` into what the connection sends, rendering
//// `Problem` bodies in the format the client accepts.

import gleam/bytes_tree.{type BytesTree}
import gleam/http/response.{type Response}
import gleam/json
import gleam/string
import gloss/http/reply.{type ErrorPage, ErrorPage}
import gloss/internal/http_reply_negotiate as reply_negotiate
import gloss/internal/http_status as status

/// Error formats, in the order preferred when the client has no preference.
const problem_types = [
  "application/json",
  "application/problem+json",
  "text/html",
  "text/plain",
]

/// A response body ready for the connection.
pub type Wire {
  Sized(BytesTree)
  SendFile(path: String, offset: Int, length: Int)
}

pub fn length(wire: Wire) -> Int {
  case wire {
    Sized(tree) -> bytes_tree.byte_size(tree)
    SendFile(length:, ..) -> length
  }
}

pub fn render(
  res: reply.Response,
  accept: Result(String, Nil),
  error_page: fn(ErrorPage) -> String,
) -> Response(Wire) {
  case res.body {
    reply.File(path:, offset:, length:) ->
      response.set_body(res, SendFile(path:, offset:, length:))
    reply.Json(body) ->
      bytes(res, json.to_string_tree(body) |> bytes_tree.from_string_tree)
    reply.Text(body) -> bytes(res, bytes_tree.from_string(body))
    reply.Bytes(body) -> bytes(res, body)
    reply.Empty -> bytes(res, bytes_tree.new())
    reply.Problem(message:, details:) -> {
      let media = case reply_negotiate.choose(accept, problem_types) {
        Ok(media) -> media
        Error(Nil) -> "application/json"
      }
      let #(content_type, body) =
        problem_body(media, res.status, message, details, error_page)
      bytes(res, bytes_tree.from_string(body))
      |> response.set_header("content-type", content_type)
      |> response.set_header("vary", "accept")
    }
  }
}

fn bytes(res: reply.Response, body: BytesTree) -> Response(Wire) {
  response.set_body(res, Sized(body))
}

fn problem_body(
  media: String,
  code: Int,
  message: String,
  details: List(String),
  error_page: fn(ErrorPage) -> String,
) -> #(String, String) {
  let errors = case details {
    [] -> []
    _ -> [#("errors", json.array(details, json.string))]
  }
  case media {
    "application/problem+json" -> #(
      "application/problem+json",
      json.object([
        #("type", json.string("about:blank")),
        #("title", json.string(status.reason(code))),
        #("status", json.int(code)),
        #("detail", json.string(message)),
        ..errors
      ])
        |> json.to_string,
    )
    "text/html" -> #(
      "text/html; charset=utf-8",
      error_page(ErrorPage(
        status: code,
        title: status.reason(code),
        message:,
        details:,
      )),
    )
    "text/plain" -> #(
      "text/plain; charset=utf-8",
      string.join([message, ..details], "\n"),
    )
    _ -> #(
      "application/json",
      json.object([#("error", json.string(message)), ..errors])
        |> json.to_string,
    )
  }
}

//// Request and response types, and functions that build responses.
////
//// ```gleam
//// reply.json(200, json.object([#("id", json.int(note.id))]))
//// reply.error(409, "title already taken")
//// reply.not_found()
//// ```
////
//// ## Errors follow the client's `Accept` header
////
//// `error` and the shortcuts built on it (`not_found`, `bad_request`, ...)
//// return a `Problem` body that has no format yet. The server renders it in
//// the format the request's `Accept` header prefers:
////
//// | Media type | Body |
//// |---|---|
//// | `application/json` | `{"error": message, "errors": [details]}` |
//// | `application/problem+json` | RFC 9457: `type`, `title`, `status`, `detail`, and `errors` |
//// | `text/html` | the server's error page (see `server.error_page`) |
//// | `text/plain` | the message, then one detail per line |
////
//// JSON is used when there is no `Accept` header, for `*/*`, and when the
//// client accepts none of these. `errors` is left out when there are no
//// details.

import gleam/bytes_tree.{type BytesTree}
import gleam/http/request
import gleam/http/response
import gleam/json.{type Json}
import gleam/list
import gleam/string
import gloss/internal/http_reply_negotiate as reply_negotiate

/// A request whose body has been read in full.
pub type Request =
  request.Request(BitArray)

pub type Response =
  response.Response(Body)

pub type Body {
  Json(Json)
  Text(String)
  Bytes(BytesTree)
  Empty
  /// An error, rendered by the server in the format the client accepts.
  Problem(message: String, details: List(String))
  /// `length` bytes of the file at `path` from `offset`, sent by the
  /// operating system without reading them into memory. See
  /// `gloss/http/static`.
  File(path: String, offset: Int, length: Int)
}

/// A JSON body with `content-type: application/json`.
pub fn json(status: Int, body: Json) -> Response {
  response.new(status)
  |> response.set_body(Json(body))
  |> response.set_header("content-type", "application/json")
}

/// A plain-text body with `content-type: text/plain; charset=utf-8`.
pub fn text(status: Int, body: String) -> Response {
  response.new(status)
  |> response.set_body(Text(body))
  |> response.set_header("content-type", "text/plain; charset=utf-8")
}

/// An HTML body with `content-type: text/html; charset=utf-8`. The text is
/// sent as-is: escape anything that came from users.
pub fn html(status: Int, body: String) -> Response {
  response.new(status)
  |> response.set_body(Text(body))
  |> response.set_header("content-type", "text/html; charset=utf-8")
}

/// Raw bytes with the given `content-type`.
pub fn bytes(status: Int, content_type: String, body: BytesTree) -> Response {
  response.new(status)
  |> response.set_body(Bytes(body))
  |> response.set_header("content-type", content_type)
}

/// A response with no body, e.g. `empty(204)`.
pub fn empty(status: Int) -> Response {
  response.new(status) |> response.set_body(Empty)
}

/// A `303 See Other` to `location`.
pub fn redirect(location: String) -> Response {
  empty(303) |> response.set_header("location", location)
}

/// An error with the given status, in the format the client accepts.
pub fn error(status: Int, message: String) -> Response {
  problem(status, message, [])
}

/// An error with a list of details, such as validation failures.
pub fn problem(
  status: Int,
  message: String,
  details: List(String),
) -> Response {
  response.new(status) |> response.set_body(Problem(message:, details:))
}

pub fn bad_request(message: String) -> Response {
  error(400, message)
}

pub fn unauthorized() -> Response {
  error(401, "unauthorized")
}

pub fn forbidden() -> Response {
  error(403, "forbidden")
}

pub fn not_found() -> Response {
  error(404, "not found")
}

/// `422` listing what is wrong with the request.
pub fn unprocessable(errors: List(String)) -> Response {
  problem(422, "unprocessable content", errors)
}

pub fn internal_error() -> Response {
  error(500, "internal server error")
}

/// The media type in `offered` that the request's `Accept` header prefers,
/// for handlers that serve more than one format. Without an `Accept`
/// header the first offer is preferred.
///
/// ```gleam
/// case reply.preferred(req, ["application/json", "text/html"]) {
///   Ok("text/html") -> reply.html(200, page(note))
///   _ -> reply.json(200, note_json(note))
/// }
/// ```
pub fn preferred(req: Request, offered: List(String)) -> Result(String, Nil) {
  reply_negotiate.choose(request.get_header(req, "accept"), offered)
}

/// What an HTML error page is given to render.
pub type ErrorPage {
  ErrorPage(
    status: Int,
    /// The status's reason phrase, e.g. `"Not Found"`.
    title: String,
    message: String,
    details: List(String),
  )
}

/// A minimal HTML page: the title as a heading, the message, and the
/// details as a list. Everything is escaped.
pub fn default_error_page(page: ErrorPage) -> String {
  let details = case page.details {
    [] -> ""
    details ->
      "<ul>"
      <> string.concat(
        list.map(details, fn(d) { "<li>" <> escape(d) <> "</li>" }),
      )
      <> "</ul>"
  }
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>"
  <> escape(page.title)
  <> "</title></head><body><h1>"
  <> escape(page.title)
  <> "</h1><p>"
  <> escape(page.message)
  <> "</p>"
  <> details
  <> "</body></html>"
}

/// Escape text for HTML element content and attribute values.
pub fn escape(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}

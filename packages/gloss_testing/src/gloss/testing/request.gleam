//// Requests for tests, built the way a client would send them.
////
//// ```gleam
//// request.post("/notes")
//// |> request.json(json.object([#("title", json.string("milk"))]))
//// |> request.header("authorization", "Bearer t")
//// |> server.handle(builder, _)
//// ```

import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/json.{type Json}
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/uri
import gloss/http/body
import gloss/http/reply.{type Request}

/// A request with no body. `path` may carry a query string: `"/?page=2"`.
pub fn new(method: http.Method, path: String) -> Request {
  let #(path, query) = case string.split_once(path, "?") {
    Ok(#(path, query)) -> #(path, Ok(query))
    Error(Nil) -> #(path, Error(Nil))
  }
  let req =
    request.new()
    |> request.set_method(method)
    |> request.set_path(path)
    |> request.set_body(body.from_bits(<<>>))
  case query {
    Ok(query) -> request.Request(..req, query: Some(query))
    Error(Nil) -> req
  }
}

pub fn get(path: String) -> Request {
  new(http.Get, path)
}

pub fn post(path: String) -> Request {
  new(http.Post, path)
}

pub fn put(path: String) -> Request {
  new(http.Put, path)
}

pub fn patch(path: String) -> Request {
  new(http.Patch, path)
}

pub fn delete(path: String) -> Request {
  new(http.Delete, path)
}

/// Set a header, replacing any value it had.
pub fn header(req: Request, name: String, value: String) -> Request {
  request.set_header(req, string.lowercase(name), value)
}

/// Add a cookie to the `cookie` header.
pub fn cookie(req: Request, name: String, value: String) -> Request {
  let pair = name <> "=" <> value
  case request.get_header(req, "cookie") {
    Ok(existing) -> header(req, "cookie", existing <> "; " <> pair)
    Error(Nil) -> header(req, "cookie", pair)
  }
}

/// A URL-encoded form body, as a browser submits a `<form>`.
pub fn form(req: Request, fields: List(#(String, String))) -> Request {
  req
  |> header("content-type", "application/x-www-form-urlencoded")
  |> request.set_body(body.from_string(uri.query_to_string(fields)))
}

pub fn json(req: Request, value: Json) -> Request {
  req
  |> header("content-type", "application/json")
  |> request.set_body(body.from_string(json.to_string(value)))
}

/// A body of any kind, with its content type.
pub fn bits(req: Request, content_type: String, data: BitArray) -> Request {
  req
  |> header("content-type", content_type)
  |> request.set_body(body.from_bits(data))
}

/// A part of a multipart form.
pub type Part {
  Field(name: String, value: String)
  File(name: String, filename: String, content_type: String, data: BitArray)
}

/// A `multipart/form-data` body, as a browser submits a form with a file.
pub fn multipart(req: Request, parts: List(Part)) -> Request {
  let boundary = "gloss-test-boundary"
  let encoded =
    list.fold(parts, <<>>, fn(acc, part) {
      let head = case part {
        Field(name:, ..) ->
          "Content-Disposition: form-data; name=\"" <> name <> "\"\r\n"
        File(name:, filename:, content_type:, ..) ->
          "Content-Disposition: form-data; name=\""
          <> name
          <> "\"; filename=\""
          <> filename
          <> "\"\r\nContent-Type: "
          <> content_type
          <> "\r\n"
      }
      let data = case part {
        Field(value:, ..) -> bit_array.from_string(value)
        File(data:, ..) -> data
      }
      <<
        acc:bits,
        "--":utf8,
        boundary:utf8,
        "\r\n":utf8,
        head:utf8,
        "\r\n":utf8,
        data:bits,
        "\r\n":utf8,
      >>
    })
  bits(req, "multipart/form-data; boundary=" <> boundary, <<
    encoded:bits,
    "--":utf8,
    boundary:utf8,
    "--\r\n":utf8,
  >>)
}

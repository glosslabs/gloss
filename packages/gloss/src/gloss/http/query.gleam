//// Read the query string: `/notes?page=2&tag=a&tag=b`.
////
//// ```gleam
//// pub fn index(req: Request, ctx: Context(State)) -> Response {
////   use page <- query.optional_int(req, "page", 1)
////   let tags = query.get_all(req, "tag")
////   ...
//// }
//// ```
////
//// Names and values are percent-decoded, and `+` is a space. A malformed
//// query string reads as empty.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/uri
import gloss/http/reply.{type Request, type Response}

/// Every parameter, in order.
pub fn all(req: Request) -> List(#(String, String)) {
  case req.query {
    Some(query) ->
      case uri.parse_query(query) {
        Ok(pairs) -> pairs
        Error(Nil) -> []
      }
    None -> []
  }
}

/// The first value of the parameter `name`.
pub fn get(req: Request, name: String) -> Result(String, Nil) {
  list.key_find(all(req), name)
}

/// Every value of the parameter `name`, in order.
pub fn get_all(req: Request, name: String) -> List(String) {
  all(req)
  |> list.filter_map(fn(pair) {
    case pair.0 == name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}

/// Continue with the parameter `name`, or answer `400` when it is missing.
pub fn string(
  req: Request,
  name: String,
  next: fn(String) -> Response,
) -> Response {
  case get(req, name) {
    Ok(value) -> next(value)
    Error(Nil) -> reply.bad_request("missing query parameter " <> name)
  }
}

/// Continue with the parameter `name` as an integer, or answer `400` when
/// it is missing or not an integer.
pub fn int(req: Request, name: String, next: fn(Int) -> Response) -> Response {
  use value <- string(req, name)
  parse_int(name, value, next)
}

/// Continue with the parameter `name` as an integer, or `default` when it
/// is absent. Answers `400` when it is present but not an integer.
pub fn optional_int(
  req: Request,
  name: String,
  default: Int,
  next: fn(Int) -> Response,
) -> Response {
  case get(req, name) {
    Ok(value) -> parse_int(name, value, next)
    Error(Nil) -> next(default)
  }
}

fn parse_int(
  name: String,
  value: String,
  next: fn(Int) -> Response,
) -> Response {
  case int.parse(value) {
    Ok(n) -> next(n)
    Error(Nil) ->
      reply.bad_request("query parameter " <> name <> " must be an integer")
  }
}

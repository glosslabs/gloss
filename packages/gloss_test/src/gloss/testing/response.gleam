//// Reading responses in tests: the body as text or JSON, headers, the
//// redirect target and cookies.
////
//// ```gleam
//// let res = server.handle(builder, request.get("/notes/1"))
//// assert res.status == 200
//// assert response.json(res, note_decoder()) == Ok(Note("milk"))
//// ```

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic/decode.{type Decoder}
import gleam/http/response
import gleam/json
import gleam/list
import gleam/string

/// What `server.handle` returns.
pub type Response =
  response.Response(BytesTree)

/// The body as text. Panics if it isn't UTF-8, which in a test is a
/// failure worth seeing.
pub fn text(res: Response) -> String {
  let assert Ok(text) = bit_array.to_string(bits(res))
    as "the response body is not UTF-8"
  text
}

pub fn bits(res: Response) -> BitArray {
  bytes_tree.to_bit_array(res.body)
}

/// The body decoded as JSON.
pub fn json(res: Response, decoder: Decoder(a)) -> Result(a, json.DecodeError) {
  json.parse_bits(bits(res), decoder)
}

/// A header's value. Names are matched case-insensitively.
pub fn header(res: Response, name: String) -> Result(String, Nil) {
  response.get_header(res, string.lowercase(name))
}

/// Where a redirect points.
pub fn location(res: Response) -> Result(String, Nil) {
  header(res, "location")
}

/// The value a `set-cookie` header gives the cookie `name`.
pub fn cookie(res: Response, name: String) -> Result(String, Nil) {
  set_cookies(res)
  |> list.find_map(fn(cookie) {
    case cookie.0 == name {
      True -> Ok(cookie.1)
      False -> Error(Nil)
    }
  })
}

/// Every `set-cookie` header as its name, value and attributes, with
/// attribute names lowercased: `#("session", "abc", [#("path", "/")])`.
pub fn set_cookies(
  res: Response,
) -> List(#(String, String, List(#(String, String)))) {
  res.headers
  |> list.filter_map(fn(header) {
    case header {
      #("set-cookie", value) -> parse_set_cookie(value)
      _ -> Error(Nil)
    }
  })
}

fn parse_set_cookie(
  value: String,
) -> Result(#(String, String, List(#(String, String))), Nil) {
  case string.split(value, ";") {
    [pair, ..attributes] ->
      case string.split_once(string.trim(pair), "=") {
        Ok(#(name, value)) ->
          Ok(#(
            name,
            value,
            list.map(attributes, fn(attribute) {
              case string.split_once(string.trim(attribute), "=") {
                Ok(#(key, value)) -> #(string.lowercase(key), value)
                Error(Nil) -> #(string.lowercase(string.trim(attribute)), "")
              }
            }),
          ))
        Error(Nil) -> Error(Nil)
      }
    [] -> Error(Nil)
  }
}

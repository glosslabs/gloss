//// Read request bodies, answering the client directly when the body is not
//// what the handler expects.
////
//// ```gleam
//// pub fn create(req: Request, ctx: Context(App)) -> Response {
////   use input <- body.json(req, note_input_decoder())
////   let note = notes.create(ctx.app.notes, input.title)
////   reply.json(201, note_json(note))
//// }
//// ```

import gleam/bit_array
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request
import gleam/json
import gleam/list
import gleam/string
import gloss/http/reply.{type Request, type Response}

/// Continue with the body decoded as JSON. Answers `415` unless the
/// `content-type` is `application/json` (parameters such as `charset` are
/// allowed), `400` when the body is not valid JSON, and `422` listing the
/// decode errors when it does not match `decoder`.
pub fn json(
  req: Request,
  decoder: Decoder(a),
  next: fn(a) -> Response,
) -> Response {
  case is_json(req) {
    False -> reply.error(415, "expected content-type application/json")
    True ->
      case json.parse_bits(req.body, decoder) {
        Ok(value) -> next(value)
        Error(json.UnableToDecode(errors)) ->
          reply.unprocessable(list.map(errors, describe))
        Error(_) -> reply.bad_request("invalid JSON")
      }
  }
}

/// Continue with the body as text. Answers `400` when it is not UTF-8.
pub fn text(req: Request, next: fn(String) -> Response) -> Response {
  case bit_array.to_string(req.body) {
    Ok(text) -> next(text)
    Error(Nil) -> reply.bad_request("the body is not valid UTF-8")
  }
}

fn is_json(req: Request) -> Bool {
  case request.get_header(req, "content-type") {
    Ok(value) ->
      case string.split(value, ";") {
        [mime, ..] -> string.lowercase(string.trim(mime)) == "application/json"
        [] -> False
      }
    Error(Nil) -> False
  }
}

/// `"title: expected String, found Int"`, or without the path for the
/// whole document.
fn describe(error: decode.DecodeError) -> String {
  let expected = "expected " <> error.expected <> ", found " <> error.found
  case error.path {
    [] -> expected
    path -> string.join(path, ".") <> ": " <> expected
  }
}

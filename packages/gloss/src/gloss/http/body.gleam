//// Read request bodies. Nothing is read until a handler asks, so a handler
//// can reject a request before its body is sent, and large uploads can be
//// streamed instead of held in memory.
////
//// ```gleam
//// pub fn create(req: Request, ctx: Context(State)) -> Response {
////   use input <- body.json(req, note_input_decoder())
////   let note = notes.create(ctx.state.notes, input.title)
////   reply.json(201, note_json(note))
//// }
////
//// pub fn upload(req: Request, ctx: Context(State)) -> Response {
////   use file <- with_temp_file()
////   use result <- body.stream(req, fn(chunk) { write(file, chunk) })
////   case result {
////     Ok(bytes) -> reply.json(201, uploaded_json(bytes))
////     Error(body.Failed(error)) -> body.error_response(error)
////     Error(body.Stopped(_disk_full)) -> reply.error(507, "disk full")
////   }
//// }
//// ```
////
//// `bits`, `text` and `json` read the whole body, up to the server's
//// `max_body`, and answer the client themselves when it is too large
//// (`413`), malformed (`400`) or not sent in time (`408`). They can be used
//// more than once: later reads get the same bytes. `stream` hands the body
//// over piece by piece with no size limit of its own, and reads it only
//// once.
////
//// Bodies are read from the connection by the handler's own process. A
//// body that the handler leaves unread, or stops streaming part way, closes
//// the connection after the response.

import gleam/bit_array
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process
import gleam/http/request
import gleam/json
import gleam/list
import gleam/string
import gloss/http/reply.{type Request, type RequestBody, type Response}
import gloss/internal/http_request_body as request_body

pub type BodyError =
  request_body.BodyError

pub type StreamError(e) {
  /// The body couldn't be read.
  Failed(BodyError)
  /// The chunk handler returned this error, and reading stopped.
  Stopped(e)
}

/// A body holding `bits`, for building requests in tests:
/// `request.new() |> request.set_body(body.from_bits(<<"hi">>))`.
pub fn from_bits(bits: BitArray) -> RequestBody {
  request_body.from_bits(bits)
}

pub fn from_string(text: String) -> RequestBody {
  request_body.from_bits(bit_array.from_string(text))
}

/// The whole body, or why it couldn't be read.
pub fn read(req: Request) -> Result(BitArray, BodyError) {
  req.body.read()
}

/// Continue with the whole body, or answer the client when it can't be
/// read (see `error_response`).
pub fn bits(req: Request, next: fn(BitArray) -> Response) -> Response {
  case read(req) {
    Ok(bits) -> next(bits)
    Error(error) -> error_response(error)
  }
}

/// Continue with the body as text. Answers `400` when it is not UTF-8.
pub fn text(req: Request, next: fn(String) -> Response) -> Response {
  use bits <- bits(req)
  case bit_array.to_string(bits) {
    Ok(text) -> next(text)
    Error(Nil) -> reply.bad_request("the body is not valid UTF-8")
  }
}

/// Continue with the body decoded as JSON. Answers `415` unless the
/// `content-type` is `application/json` (parameters such as `charset` are
/// allowed), `400` when the body is not valid JSON, and `422` listing the
/// decode errors when it does not match `decoder`. The content type is
/// checked before the body is read.
pub fn json(
  req: Request,
  decoder: Decoder(a),
  next: fn(a) -> Response,
) -> Response {
  case is_json(req) {
    False -> reply.error(415, "expected content-type application/json")
    True -> {
      use bits <- bits(req)
      case json.parse_bits(bits, decoder) {
        Ok(value) -> next(value)
        Error(json.UnableToDecode(errors)) ->
          reply.unprocessable(list.map(errors, describe))
        Error(_) -> reply.bad_request("invalid JSON")
      }
    }
  }
}

/// Hand each piece of the body to `on_chunk` as it arrives, then continue
/// with the number of bytes read. Return an `Error` from `on_chunk` to stop
/// reading, e.g. when a size limit is reached. There is no limit besides
/// the ones `on_chunk` applies.
pub fn stream(
  req: Request,
  on_chunk: fn(BitArray) -> Result(Nil, e),
  next: fn(Result(Int, StreamError(e))) -> Response,
) -> Response {
  let stopped = process.new_subject()
  let result =
    req.body.stream(fn(chunk) {
      case on_chunk(chunk) {
        Ok(Nil) -> True
        Error(error) -> {
          process.send(stopped, error)
          False
        }
      }
    })
  next(case result {
    Ok(bytes) -> Ok(bytes)
    Error(request_body.Stopped) ->
      case process.receive(stopped, 0) {
        Ok(error) -> Error(Stopped(error))
        Error(Nil) -> Error(Failed(request_body.Stopped))
      }
    Error(error) -> Error(Failed(error))
  })
}

/// The response for a body that couldn't be read: `413` when too large,
/// `400` when malformed, `408` when the client didn't send it in time, and
/// `500` when it was already streamed.
pub fn error_response(error: BodyError) -> Response {
  case error {
    request_body.TooLarge(_) -> reply.error(413, "content too large")
    request_body.Malformed(reason) -> reply.bad_request(reason)
    request_body.Incomplete -> reply.error(408, "request body not received")
    request_body.Consumed | request_body.Stopped -> reply.internal_error()
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

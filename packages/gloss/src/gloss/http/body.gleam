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
//// Bodies sent with `content-encoding: gzip` are inflated as they are read;
//// the size limits apply to the inflated bytes, so a small compressed body
//// can't expand without limit.
////
//// Bodies are read from the connection by the handler's own process. A
//// body that the handler leaves unread, or stops streaming part way, closes
//// the connection after the response.

import gleam/bit_array
import gleam/bool
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gloss/http/reply.{type Request, type RequestBody, type Response}
import gloss/internal/http_multipart as multipart
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

/// Fold each piece of the body into an accumulator as it arrives, then
/// continue with the result. Return an `Error` from `on_chunk` to stop. Like
/// `stream`, there is no size limit besides the ones `on_chunk` applies.
pub fn fold(
  req: Request,
  init: acc,
  on_chunk: fn(acc, BitArray) -> Result(acc, e),
  next: fn(Result(acc, StreamError(e))) -> Response,
) -> Response {
  // The body hands chunks to a callback with no state of its own, so the
  // accumulator waits in a mailbox between chunks.
  let cell = process.new_subject()
  let stopped = process.new_subject()
  process.send(cell, init)
  let result =
    req.body.stream(fn(chunk) {
      let assert Ok(acc) = process.receive(cell, 0)
      case on_chunk(acc, chunk) {
        Ok(acc) -> {
          process.send(cell, acc)
          True
        }
        Error(error) -> {
          process.send(stopped, error)
          False
        }
      }
    })
  next(case result {
    Ok(_) -> {
      let assert Ok(acc) = process.receive(cell, 0)
      Ok(acc)
    }
    Error(request_body.Stopped) ->
      case process.receive(stopped, 0) {
        Ok(error) -> Error(Stopped(error))
        Error(Nil) -> Error(Failed(request_body.Stopped))
      }
    Error(error) -> Error(Failed(error))
  })
}

/// A submitted HTML form.
pub type Form {
  Form(
    /// Text fields, in the order sent. A name can appear more than once.
    values: List(#(String, String)),
    /// Uploaded files, by field name, in the order sent.
    files: List(#(String, UploadedFile)),
  )
}

pub type UploadedFile {
  UploadedFile(filename: String, content_type: String, data: BitArray)
}

/// Continue with the submitted form, sent as
/// `application/x-www-form-urlencoded` or `multipart/form-data`. Files are
/// held in memory, and the whole form must fit in the server's `max_body`
/// (else `413`); stream large uploads with `gloss/http/multipart` instead.
/// Answers `415` for other content types and `400` for malformed forms.
pub fn form(req: Request, next: fn(Form) -> Response) -> Response {
  let content_type =
    request.get_header(req, "content-type") |> result.unwrap("")
  case media_type(content_type) {
    "application/x-www-form-urlencoded" -> {
      use text <- text(req)
      case uri.parse_query(text) {
        Ok(values) -> next(Form(values:, files: []))
        Error(Nil) -> reply.bad_request("invalid form")
      }
    }
    "multipart/form-data" ->
      case multipart.boundary(content_type) {
        Ok(boundary) -> multipart_form(req, boundary, next)
        Error(Nil) -> reply.bad_request("missing multipart boundary")
      }
    _ -> reply.error(415, "expected a form")
  }
}

type FormState {
  FormState(
    parser: multipart.Parser,
    size: Int,
    /// The part being read and its content so far, newest first.
    current: Option(#(multipart.Part, List(BitArray))),
    values: List(#(String, String)),
    files: List(#(String, UploadedFile)),
  )
}

type FormError {
  FormTooLarge
  Unparsable(multipart.ParseError)
  NotText(field: String)
}

fn multipart_form(
  req: Request,
  boundary: String,
  next: fn(Form) -> Response,
) -> Response {
  let limit = req.body.limit
  let init =
    FormState(
      parser: multipart.new(boundary),
      size: 0,
      current: None,
      values: [],
      files: [],
    )
  use result <- fold(req, init, fn(state, chunk) {
    let size = state.size + bit_array.byte_size(chunk)
    use <- bool.guard(size > limit, Error(FormTooLarge))
    use #(parser, events) <- result.try(
      multipart.feed(state.parser, chunk) |> result.map_error(Unparsable),
    )
    list.try_fold(events, FormState(..state, parser:, size:), collect)
  })
  case result {
    Ok(state) ->
      case multipart.finish(state.parser) {
        Ok(Nil) ->
          next(Form(
            values: list.reverse(state.values),
            files: list.reverse(state.files),
          ))
        Error(error) -> form_error(Unparsable(error))
      }
    Error(Stopped(error)) -> form_error(error)
    Error(Failed(error)) -> error_response(error)
  }
}

fn collect(
  state: FormState,
  event: multipart.Event,
) -> Result(FormState, FormError) {
  case event, state.current {
    multipart.Start(part), _ ->
      Ok(FormState(..state, current: Some(#(part, []))))
    multipart.Data(data), Some(#(part, pieces)) ->
      Ok(FormState(..state, current: Some(#(part, [data, ..pieces]))))
    multipart.End, Some(#(part, pieces)) -> {
      let data = bit_array.concat(list.reverse(pieces))
      let state = FormState(..state, current: None)
      case part.filename {
        Some(filename) -> {
          let file =
            UploadedFile(filename:, content_type: part.content_type, data:)
          Ok(FormState(..state, files: [#(part.name, file), ..state.files]))
        }
        None ->
          case bit_array.to_string(data) {
            Ok(text) ->
              Ok(
                FormState(..state, values: [#(part.name, text), ..state.values]),
              )
            Error(Nil) -> Error(NotText(part.name))
          }
      }
    }
    _, None -> Ok(state)
  }
}

fn form_error(error: FormError) -> Response {
  case error {
    FormTooLarge -> reply.error(413, "content too large")
    Unparsable(multipart.Malformed(reason)) -> reply.bad_request(reason)
    Unparsable(multipart.TooManyParts(limit)) ->
      reply.error(413, "more than " <> int.to_string(limit) <> " form fields")
    NotText(field) -> reply.bad_request(field <> " is not valid UTF-8")
  }
}

fn media_type(content_type: String) -> String {
  case string.split(content_type, ";") {
    [media, ..] -> string.lowercase(string.trim(media))
    [] -> ""
  }
}

/// The response for a body that couldn't be read: `413` when too large,
/// `400` when malformed, `408` when the client didn't send it in time,
/// `415` for a `content-encoding` other than gzip, and `500` when it was
/// already streamed.
pub fn error_response(error: BodyError) -> Response {
  case error {
    request_body.TooLarge(_) -> reply.error(413, "content too large")
    request_body.Malformed(reason) -> reply.bad_request(reason)
    request_body.Incomplete -> reply.error(408, "request body not received")
    request_body.UnsupportedEncoding(coding) ->
      reply.error(415, "unsupported content-encoding " <> coding)
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

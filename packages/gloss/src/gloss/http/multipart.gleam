//// Stream `multipart/form-data` uploads part by part, so large files go
//// to disk or storage without being held in memory. For small forms,
//// `body.form` is simpler.
////
//// ```gleam
//// // Count each field's bytes without keeping them; a real handler would
//// // write `Data` chunks to a file or object store instead.
//// pub fn upload(req: Request, _ctx: Context(State)) -> Response {
////   use result <- multipart.fold(req, [], fn(sizes, event) {
////     case event, sizes {
////       multipart.Start(part), _ -> Ok([#(part.name, 0), ..sizes])
////       multipart.Data(chunk), [#(name, size), ..rest] ->
////         Ok([#(name, size + bit_array.byte_size(chunk)), ..rest])
////       _, _ -> Ok(sizes)
////     }
////   })
////   case result {
////     Ok(sizes) -> reply.json(201, sizes_json(sizes))
////     Error(error) -> multipart.error_response(error)
////   }
//// }
//// ```
////
//// Each part is announced with `Start`, its content arrives as one or more
//// `Data` chunks, and `End` closes it. Part headers are limited to 16 KiB
//// and a body to 1000 parts; the size of the content is up to the handler.

import gleam/http/request
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gloss/http/body.{type BodyError}
import gloss/http/reply.{type Request, type Response}
import gloss/internal/http_multipart as parser

pub type Part {
  Part(
    /// The form field's name.
    name: String,
    /// The uploaded file's name, for file fields.
    filename: Option(String),
    /// `text/plain` when the part doesn't say.
    content_type: String,
    /// Every header of the part, with lowercase names.
    headers: List(#(String, String)),
  )
}

pub type Event {
  Start(Part)
  Data(BitArray)
  End
}

pub type Error(e) {
  /// Not `multipart/form-data`, or no boundary.
  NotMultipart
  Malformed(reason: String)
  TooManyParts(limit: Int)
  /// The body couldn't be read.
  Failed(BodyError)
  /// `on_event` returned this error, and reading stopped.
  Stopped(e)
}

type Inner(e) {
  Parse(parser.ParseError)
  User(e)
}

/// Fold each event of a multipart body into an accumulator, then continue
/// with the result. Return an `Error` from `on_event` to stop reading.
pub fn fold(
  req: Request,
  init: acc,
  on_event: fn(acc, Event) -> Result(acc, e),
  next: fn(Result(acc, Error(e))) -> Response,
) -> Response {
  let boundary =
    request.get_header(req, "content-type")
    |> result.try(parser.boundary)
  case boundary {
    Error(Nil) -> next(Error(NotMultipart))
    Ok(boundary) -> {
      use result <- body.fold(
        req,
        #(parser.new(boundary), init),
        fn(acc, chunk) {
          let #(state, user) = acc
          use #(state, events) <- result.try(
            parser.feed(state, chunk) |> result.map_error(Parse),
          )
          list.try_fold(events, user, fn(user, event) {
            on_event(user, public(event)) |> result.map_error(User)
          })
          |> result.map(fn(user) { #(state, user) })
        },
      )
      next(case result {
        Ok(#(state, user)) ->
          case parser.finish(state) {
            Ok(Nil) -> Ok(user)
            Error(error) -> Error(parse_error(error))
          }
        Error(body.Stopped(Parse(error))) -> Error(parse_error(error))
        Error(body.Stopped(User(error))) -> Error(Stopped(error))
        Error(body.Failed(error)) -> Error(Failed(error))
      })
    }
  }
}

/// The response for a failed multipart read: `415` when it isn't
/// multipart, `400` when malformed, `413` for too many parts, the body
/// error's response (see `body.error_response`), and `500` when the
/// handler stopped reading, as it should answer that itself.
pub fn error_response(error: Error(e)) -> Response {
  case error {
    NotMultipart -> reply.error(415, "expected multipart/form-data")
    Malformed(reason) -> reply.bad_request(reason)
    TooManyParts(_) -> reply.error(413, "too many form fields")
    Failed(error) -> body.error_response(error)
    Stopped(_) -> reply.internal_error()
  }
}

fn public(event: parser.Event) -> Event {
  case event {
    parser.Start(part) ->
      Start(Part(
        name: part.name,
        filename: part.filename,
        content_type: part.content_type,
        headers: part.headers,
      ))
    parser.Data(data) -> Data(data)
    parser.End -> End
  }
}

fn parse_error(error: parser.ParseError) -> Error(e) {
  case error {
    parser.Malformed(reason) -> Malformed(reason)
    parser.TooManyParts(limit) -> TooManyParts(limit)
  }
}

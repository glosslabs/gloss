//// Save an uploaded file to disk as it arrives, never holding it in
//// memory.
////
//// ```gleam
//// pub fn upload_avatar(req: Request, ctx: Context(State)) -> Response {
////   let config =
////     upload.new(field: "avatar", dir: ctx.state.avatars_dir)
////     |> upload.max_bytes(2_000_000)
////     |> upload.accept(["image/png", "image/jpeg", "image/gif", "image/webp"])
////   use result <- upload.save(req, config)
////   case result {
////     Ok(file) -> set_avatar(ctx, file.name)
////     Error(error) -> upload.error_response(error)
////   }
//// }
//// ```
////
//// `save` reads a `multipart/form-data` body and streams the named file
//// field to a temporary file in `dir`, refusing it as soon as its content
//// type or size is wrong. Once the whole body has arrived the file is
//// renamed to a random name, with an extension from its content type (the
//// client's file name is never used for the path). On any failure the
//// partial file is deleted. Other fields in the form are skipped.

import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloss/http/multipart
import gloss/http/reply.{type Request, type Response}

pub opaque type Config {
  Config(field: String, dir: String, max_bytes: Int, accept: List(String))
}

pub type Uploaded {
  Uploaded(
    /// The saved file's name in `dir`, e.g. `"3f9a1c2b7d4e8f60.png"`.
    name: String,
    /// `dir` and `name` joined.
    path: String,
    /// The name the client gave the file. For display only.
    filename: String,
    content_type: String,
    /// In bytes.
    size: Int,
  )
}

pub type UploadError {
  /// The form had no file in the field.
  NoFile
  UnsupportedType(content_type: String)
  TooLarge(limit: Int)
  /// The file couldn't be written to `dir`.
  WriteFailed
  /// The body wasn't a readable multipart form.
  Unreadable(multipart.Error(UploadError))
}

/// Save the file in `field` to `dir`. Defaults: at most 10 MB, any type.
pub fn new(field field: String, dir dir: String) -> Config {
  Config(field:, dir:, max_bytes: 10_000_000, accept: [])
}

/// The largest file accepted, in bytes.
pub fn max_bytes(config: Config, bytes: Int) -> Config {
  Config(..config, max_bytes: bytes)
}

/// The content types accepted, e.g. `["image/png", "image/jpeg"]`. An
/// empty list accepts any type.
pub fn accept(config: Config, content_types: List(String)) -> Config {
  Config(..config, accept: list.map(content_types, string.lowercase))
}

type Saving {
  Saving(
    /// The file being written and its content type, while its part lasts.
    writing: Option(#(Device, String, String)),
    size: Int,
    /// The finished file's original name and content type.
    saved: Option(#(String, String)),
  )
}

/// Stream the upload to disk, then continue with the saved file or why it
/// wasn't saved.
pub fn save(
  req: Request,
  config: Config,
  next: fn(Result(Uploaded, UploadError)) -> Response,
) -> Response {
  let temp = config.dir <> "/.upload-" <> random_name()
  let start = Saving(writing: None, size: 0, saved: None)
  use result <- multipart.fold(req, start, fn(saving, event) {
    case event, saving.writing {
      multipart.Start(part), _ ->
        case part.name == config.field, part.filename, saving.saved {
          True, Some(filename), None if filename != "" -> {
            let content_type = string.lowercase(part.content_type)
            use Nil <- result.try(check_type(config, content_type))
            use device <- result.map(
              open(temp) |> result.replace_error(WriteFailed),
            )
            Saving(..saving, writing: Some(#(device, filename, content_type)))
          }
          _, _, _ -> Ok(saving)
        }
      multipart.Data(chunk), Some(#(device, _, _)) -> {
        let size = saving.size + bit_array.byte_size(chunk)
        case size > config.max_bytes {
          True -> Error(TooLarge(config.max_bytes))
          False ->
            write(device, chunk)
            |> result.replace(Saving(..saving, size:))
            |> result.replace_error(WriteFailed)
        }
      }
      multipart.End, Some(#(device, filename, content_type)) -> {
        close(device)
        Ok(
          Saving(
            ..saving,
            writing: None,
            saved: Some(#(filename, content_type)),
          ),
        )
      }
      _, _ -> Ok(saving)
    }
  })
  next(case result {
    Ok(Saving(saved: Some(#(filename, content_type)), size:, ..)) -> {
      let name = random_name() <> extension(content_type)
      let path = config.dir <> "/" <> name
      case rename(temp, path) {
        Ok(Nil) -> Ok(Uploaded(name:, path:, filename:, content_type:, size:))
        Error(Nil) -> {
          remove(temp)
          Error(WriteFailed)
        }
      }
    }
    Ok(_) -> Error(NoFile)
    Error(error) -> {
      remove(temp)
      case error {
        multipart.Stopped(error) -> Error(error)
        other -> Error(Unreadable(other))
      }
    }
  })
}

/// A JSON-style error reply: `422` for no file, `415` for the wrong type,
/// `413` when too large, `500` when it couldn't be written, and the
/// multipart error's reply when the body was unreadable.
pub fn error_response(error: UploadError) -> Response {
  case error {
    NoFile -> reply.error(422, "no file was uploaded")
    UnsupportedType(content_type) ->
      reply.error(415, "unsupported file type " <> content_type)
    TooLarge(_) -> reply.error(413, "file too large")
    WriteFailed -> reply.internal_error()
    Unreadable(error) -> multipart.error_response(error)
  }
}

/// Delete a saved upload, e.g. one that has been replaced.
pub fn delete(path: String) -> Nil {
  remove(path)
}

fn check_type(
  config: Config,
  content_type: String,
) -> Result(Nil, UploadError) {
  case config.accept {
    [] -> Ok(Nil)
    accepted ->
      case list.contains(accepted, content_type) {
        True -> Ok(Nil)
        False -> Error(UnsupportedType(content_type))
      }
  }
}

/// A file extension for a content type, or none for unknown types.
fn extension(content_type: String) -> String {
  case content_type {
    "image/png" -> ".png"
    "image/jpeg" -> ".jpg"
    "image/gif" -> ".gif"
    "image/webp" -> ".webp"
    "image/avif" -> ".avif"
    "image/svg+xml" -> ".svg"
    "application/pdf" -> ".pdf"
    "text/plain" -> ".txt"
    "text/csv" -> ".csv"
    "application/json" -> ".json"
    "application/zip" -> ".zip"
    "video/mp4" -> ".mp4"
    "video/webm" -> ".webm"
    "audio/mpeg" -> ".mp3"
    _ -> ""
  }
}

fn random_name() -> String {
  crypto.strong_random_bytes(8)
  |> bit_array.base16_encode
  |> string.lowercase
}

type Device

@external(erlang, "gloss@http@server_ffi", "upload_open")
fn open(path: String) -> Result(Device, Nil)

@external(erlang, "gloss@http@server_ffi", "upload_write")
fn write(device: Device, data: BitArray) -> Result(Nil, Nil)

@external(erlang, "gloss@http@server_ffi", "upload_close")
fn close(device: Device) -> Nil

@external(erlang, "gloss@http@server_ffi", "upload_rename")
fn rename(from: String, to: String) -> Result(Nil, Nil)

@external(erlang, "gloss@http@server_ffi", "upload_delete")
fn remove(path: String) -> Nil

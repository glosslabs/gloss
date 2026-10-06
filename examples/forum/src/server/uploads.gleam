//// Receiving avatar uploads: streamed from the request straight to a file,
//// never held in memory.

import gleam/bit_array
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gloss/http/multipart
import gloss/http/reply.{type Request, type Response}

pub const max_avatar_bytes = 2_000_000

pub type AvatarError {
  /// No file was chosen.
  NoFile
  UnsupportedType
  TooLarge
  WriteFailed
  Unreadable(multipart.Error(AvatarError))
}

type Receiving {
  Receiving(
    writing: Option(#(Device, String)),
    size: Int,
    saved: Option(String),
  )
}

/// Stream the `avatar` field of a multipart form into `dir`, then continue
/// with the saved file's name, `<user_id>-<random>.<ext>`.
pub fn receive_avatar(
  req: Request,
  dir: String,
  user_id: Int,
  next: fn(Result(String, AvatarError)) -> Response,
) -> Response {
  let temp = dir <> "/.upload-" <> random_name()
  let start = Receiving(writing: None, size: 0, saved: None)
  use result <- multipart.fold(req, start, fn(receiving, event) {
    case event, receiving.writing {
      multipart.Start(part), _ if part.name == "avatar" ->
        case part.filename {
          None | Some("") -> Ok(receiving)
          Some(_) -> {
            use extension <- result.try(extension(part.content_type))
            use device <- result.map(
              open_write(temp) |> result.replace_error(WriteFailed),
            )
            Receiving(..receiving, writing: Some(#(device, extension)))
          }
        }
      multipart.Data(chunk), Some(#(device, _)) -> {
        let size = receiving.size + bit_array.byte_size(chunk)
        case size > max_avatar_bytes {
          True -> Error(TooLarge)
          False ->
            write(device, chunk)
            |> result.replace(Receiving(..receiving, size:))
            |> result.replace_error(WriteFailed)
        }
      }
      multipart.End, Some(#(device, extension)) -> {
        close(device)
        Ok(Receiving(..receiving, writing: None, saved: Some(extension)))
      }
      _, _ -> Ok(receiving)
    }
  })
  next(case result {
    Ok(Receiving(saved: Some(extension), ..)) -> {
      let name =
        int.to_string(user_id) <> "-" <> random_name() <> "." <> extension
      case rename(temp, dir <> "/" <> name) {
        Ok(Nil) -> Ok(name)
        Error(Nil) -> Error(WriteFailed)
      }
    }
    Ok(_) -> Error(NoFile)
    Error(error) -> {
      delete(temp)
      case error {
        multipart.Stopped(error) -> Error(error)
        other -> Error(Unreadable(other))
      }
    }
  })
}

fn extension(content_type: String) -> Result(String, AvatarError) {
  case content_type {
    "image/png" -> Ok("png")
    "image/jpeg" -> Ok("jpg")
    "image/gif" -> Ok("gif")
    "image/webp" -> Ok("webp")
    _ -> Error(UnsupportedType)
  }
}

/// Remove a replaced avatar.
pub fn remove(dir: String, name: String) -> Nil {
  delete(dir <> "/" <> name)
}

type Device

@external(erlang, "server@uploads_ffi", "open_write")
fn open_write(path: String) -> Result(Device, Nil)

@external(erlang, "server@uploads_ffi", "write")
fn write(device: Device, data: BitArray) -> Result(Nil, Nil)

@external(erlang, "server@uploads_ffi", "close")
fn close(device: Device) -> Nil

@external(erlang, "server@uploads_ffi", "rename")
fn rename(from: String, to: String) -> Result(Nil, Nil)

@external(erlang, "server@uploads_ffi", "delete")
fn delete(path: String) -> Nil

@external(erlang, "server@uploads_ffi", "random_name")
fn random_name() -> String

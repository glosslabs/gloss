//// Serving files from a directory.
////
//// ```gleam
//// let assert Ok(priv) = static.priv("app")
//// router.new()
//// |> router.get("/assets/*path", static.files(priv <> "/static"))
//// ```
////
//// The handler serves the file named by the route's `*path` wildcard.
//// Paths with `..` segments or dotfiles (`.env`, `.git/...`) are answered
//// `404`, as are directories and missing files. Files are sent by the
//// operating system without being read into memory.
////
//// Each response has a `content-type` from the file's extension, a weak
//// `etag` from its size and modification time, and `cache-control`
//// (`no-cache` by default, so clients revalidate every use and get a
//// `304 Not Modified` while the file is unchanged). For fingerprinted
//// assets (`app.3f9a1c.css`) use a long cache instead:
////
//// ```gleam
//// static.new(dir)
//// |> static.cache_control("public, max-age=31536000, immutable")
//// |> static.handler
//// ```

import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/string
import gloss/http/context.{type Context, type Handler}
import gloss/http/reply.{type Request, type Response}

pub opaque type Config {
  Config(directory: String, cache_control: String, param: String)
}

/// Serve files under `directory`, with `cache-control: no-cache`, from the
/// route's `*path` wildcard.
pub fn new(directory: String) -> Config {
  Config(directory:, cache_control: "no-cache", param: "path")
}

pub fn cache_control(config: Config, value: String) -> Config {
  Config(..config, cache_control: value)
}

/// The name of the route's wildcard, when it isn't `path`.
pub fn param(config: Config, name: String) -> Config {
  Config(..config, param: name)
}

/// `handler(new(directory))`.
pub fn files(directory: String) -> Handler(state) {
  handler(new(directory))
}

pub fn handler(config: Config) -> Handler(state) {
  fn(req: Request, ctx: Context(state)) {
    case context.param(ctx, config.param) |> result_then(safe_path) {
      Error(Nil) -> reply.not_found()
      Ok(relative) -> serve(req, config, config.directory <> "/" <> relative)
    }
  }
}

/// The `priv` directory of the OTP application `name`, where `gleam`
/// packages ship their static files.
pub fn priv(name: String) -> Result(String, Nil) {
  priv_dir(name)
}

fn serve(req: Request, config: Config, path: String) -> Response {
  case file_info(path) {
    Ok(#(size, mtime)) -> {
      let etag =
        "W/\"" <> int.to_base16(size) <> "-" <> int.to_base16(mtime) <> "\""
      case fresh(req, etag) {
        True -> reply.empty(304)
        False ->
          response.new(200)
          |> response.set_body(reply.File(path:, offset: 0, length: size))
          |> response.set_header("content-type", content_type(path))
      }
      |> response.set_header("etag", etag)
      |> response.set_header("cache-control", config.cache_control)
    }
    Error(Nil) -> reply.not_found()
  }
}

/// Whether the client's cached copy, named by `if-none-match`, is current.
fn fresh(req: Request, etag: String) -> Bool {
  case request.get_header(req, "if-none-match") {
    Ok(header) ->
      header
      |> string.split(",")
      |> list.map(string.trim)
      |> list.any(fn(tag) { tag == etag || tag == "*" })
    Error(Nil) -> False
  }
}

/// The wildcard's value as a relative path, or `Error` if it could leave
/// the directory or names a dotfile.
fn safe_path(path: String) -> Result(String, Nil) {
  let segments = string.split(path, "/") |> list.filter(fn(s) { s != "" })
  let unsafe =
    list.any(segments, fn(segment) {
      string.starts_with(segment, ".")
      || string.contains(segment, "\\")
      || string.contains(segment, "\u{0}")
    })
  case segments, unsafe {
    [], _ | _, True -> Error(Nil)
    _, False -> Ok(string.join(segments, "/"))
  }
}

fn result_then(
  result: Result(a, Nil),
  next: fn(a) -> Result(b, Nil),
) -> Result(b, Nil) {
  case result {
    Ok(value) -> next(value)
    Error(Nil) -> Error(Nil)
  }
}

/// The media type for a file name's extension.
pub fn content_type(path: String) -> String {
  let extension = case string.split(string.lowercase(path), ".") {
    [_, ..] as parts ->
      case list.last(parts) {
        Ok(extension) -> extension
        Error(Nil) -> ""
      }
    [] -> ""
  }
  case extension {
    "html" | "htm" -> "text/html; charset=utf-8"
    "css" -> "text/css; charset=utf-8"
    "js" | "mjs" -> "text/javascript; charset=utf-8"
    "json" | "map" -> "application/json"
    "txt" -> "text/plain; charset=utf-8"
    "md" -> "text/markdown; charset=utf-8"
    "csv" -> "text/csv; charset=utf-8"
    "xml" -> "application/xml"
    "svg" -> "image/svg+xml"
    "png" -> "image/png"
    "jpg" | "jpeg" -> "image/jpeg"
    "gif" -> "image/gif"
    "webp" -> "image/webp"
    "avif" -> "image/avif"
    "ico" -> "image/x-icon"
    "woff" -> "font/woff"
    "woff2" -> "font/woff2"
    "ttf" -> "font/ttf"
    "otf" -> "font/otf"
    "pdf" -> "application/pdf"
    "wasm" -> "application/wasm"
    "mp4" -> "video/mp4"
    "webm" -> "video/webm"
    "mp3" -> "audio/mpeg"
    "wav" -> "audio/wav"
    "zip" -> "application/zip"
    "gz" -> "application/gzip"
    _ -> "application/octet-stream"
  }
}

/// The size and modification time of a regular file.
@external(erlang, "gloss@http@server_ffi", "file_info")
fn file_info(path: String) -> Result(#(Int, Int), Nil)

@external(erlang, "gloss@http@server_ffi", "priv_dir")
fn priv_dir(name: String) -> Result(String, Nil)

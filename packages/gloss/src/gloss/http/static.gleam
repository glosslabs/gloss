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
//// Each response has a `content-type` from the file's extension, an `etag`
//// and `last-modified` from its size and modification time, and
//// `cache-control` (`no-cache` by default, so clients revalidate every use
//// and get a `304 Not Modified` while the file is unchanged).
////
//// Large media can be fetched in parts: a `range` header asking for one
//// byte range is answered `206 Partial Content` (or `416` when it lies
//// outside the file), so video and audio players can seek and downloads
//// can resume. `if-range` is respected. For fingerprinted
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
        "\"" <> int.to_base16(size) <> "-" <> int.to_base16(mtime) <> "\""
      let last_modified = http_date(mtime)
      let file = fn(status, offset, length) {
        response.new(status)
        |> response.set_body(reply.File(path:, offset:, length:))
        |> response.set_header("content-type", content_type(path))
      }
      case fresh(req, etag), wanted_range(req, etag, last_modified, size) {
        True, _ -> reply.empty(304)
        False, Whole -> file(200, 0, size)
        False, Part(first, last) ->
          file(206, first, last - first + 1)
          |> response.set_header(
            "content-range",
            "bytes "
              <> int.to_string(first)
              <> "-"
              <> int.to_string(last)
              <> "/"
              <> int.to_string(size),
          )
        False, Unsatisfiable ->
          reply.error(416, "range not satisfiable")
          |> response.set_header(
            "content-range",
            "bytes */" <> int.to_string(size),
          )
      }
      |> response.set_header("etag", etag)
      |> response.set_header("last-modified", last_modified)
      |> response.set_header("accept-ranges", "bytes")
      |> response.set_header("cache-control", config.cache_control)
    }
    Error(Nil) -> reply.not_found()
  }
}

/// Whether the client's cached copy, named by `if-none-match`, is current.
/// A weak comparison: `W/` prefixes are ignored.
fn fresh(req: Request, etag: String) -> Bool {
  case request.get_header(req, "if-none-match") {
    Ok(header) ->
      header
      |> string.split(",")
      |> list.map(fn(tag) {
        case string.trim(tag) {
          "W/" <> tag -> tag
          tag -> tag
        }
      })
      |> list.any(fn(tag) { tag == etag || tag == "*" })
    Error(Nil) -> False
  }
}

pub type Range {
  Whole
  /// Bytes `first` to `last`, inclusive.
  Part(first: Int, last: Int)
  Unsatisfiable
}

/// What part of the file to send. A `range` is honoured only when an
/// `if-range` header, if any, still names this version of the file.
fn wanted_range(
  req: Request,
  etag: String,
  last_modified: String,
  size: Int,
) -> Range {
  let current = case request.get_header(req, "if-range") {
    Ok(validator) -> validator == etag || validator == last_modified
    Error(Nil) -> True
  }
  case current, request.get_header(req, "range") {
    True, Ok(header) -> parse_range(header, size)
    _, _ -> Whole
  }
}

/// A `range` header against a file of `size` bytes. Only single byte
/// ranges are served; anything else, including several ranges, gets the
/// whole file.
pub fn parse_range(header: String, size: Int) -> Range {
  case string.trim(header) {
    "bytes=" <> spec ->
      case string.split(spec, ","), size {
        [_, _, ..], _ -> Whole
        _, 0 -> Unsatisfiable
        [one], _ ->
          case string.split_once(string.trim(one), "-") {
            // The last `n` bytes.
            Ok(#("", n)) ->
              case int.parse(n) {
                Ok(n) if n > 0 -> Part(int.max(size - n, 0), size - 1)
                Ok(_) -> Unsatisfiable
                Error(Nil) -> Whole
              }
            Ok(#(first, last)) ->
              case int.parse(first), last {
                Ok(first), _ if first >= size -> Unsatisfiable
                Ok(first), "" -> Part(first, size - 1)
                Ok(first), last ->
                  case int.parse(last) {
                    Ok(last) if last >= first ->
                      Part(first, int.min(last, size - 1))
                    _ -> Whole
                  }
                Error(Nil), _ -> Whole
              }
            Error(Nil) -> Whole
          }
        [], _ -> Whole
      }
    _ -> Whole
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

/// An IMF-fixdate for a time in Unix seconds.
@external(erlang, "gloss@http@server_ffi", "http_date")
fn http_date(seconds: Int) -> String

@external(erlang, "gloss@http@server_ffi", "priv_dir")
fn priv_dir(name: String) -> Result(String, Nil)

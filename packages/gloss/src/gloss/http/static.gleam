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
//// Large media can be fetched in parts: a `range` header is answered
//// `206 Partial Content` (or `416` when it lies outside the file), so video
//// and audio players can seek and downloads can resume. Several ranges are
//// sent as `multipart/byteranges`; more than 16, or overlapping ones, get
//// the whole file. `if-range` is respected. For fingerprinted
//// assets (`app.3f9a1c.css`) use a long cache instead:
////
//// ```gleam
//// static.new(dir)
//// |> static.cache_control("public, max-age=31536000, immutable")
//// |> static.handler
//// ```
////
//// A single-page app serves `index.html` for a directory and the same file
//// for every page the browser asks for that isn't a file. The wildcard
//// doesn't match an empty path, so the root gets its own route:
////
//// ```gleam
//// let app =
////   static.new(dir)
////   |> static.index(True)
////   |> static.fallback(Some("index.html"))
////   |> static.handler
//// router.new()
//// |> router.get("/", app)
//// |> router.get("/*path", app)
//// ```

import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloss/http/context.{type Context, type Handler}
import gloss/http/reply.{type Request, type Response}
import gloss/internal/http_reply_negotiate as negotiate

pub opaque type Config {
  Config(
    directory: String,
    cache_control: String,
    param: String,
    precompressed: Bool,
    index: Bool,
    fallback: Option(String),
  )
}

/// Serve files under `directory`, with `cache-control: no-cache`, from the
/// route's `*path` wildcard.
pub fn new(directory: String) -> Config {
  Config(
    directory:,
    cache_control: "no-cache",
    param: "path",
    precompressed: False,
    index: False,
    fallback: None,
  )
}

pub fn cache_control(config: Config, value: String) -> Config {
  Config(..config, cache_control: value)
}

/// The name of the route's wildcard, when it isn't `path`.
pub fn param(config: Config, name: String) -> Config {
  Config(..config, param: name)
}

/// Serve `file.br` or `file.gz`, when it exists and the client accepts
/// that encoding, in place of `file`. Build the compressed copies when the
/// assets are built, e.g. with `brotli` and `gzip -k`.
pub fn precompressed(config: Config, enabled: Bool) -> Config {
  Config(..config, precompressed: enabled)
}

/// Serve `index.html` for a directory that has one. A request for the
/// directory without a trailing slash is redirected to it with one, so the
/// page's relative links resolve.
pub fn index(config: Config, enabled: Bool) -> Config {
  Config(..config, index: enabled)
}

/// A file, relative to the directory, to serve for a request that names no
/// file, such as `index.html` for a single-page app that routes in the
/// browser. It answers only requests that accept `text/html`, so a missing
/// script or image is still `404`.
pub fn fallback(config: Config, file: Option(String)) -> Config {
  Config(..config, fallback: file)
}

/// `handler(new(directory))`.
pub fn files(directory: String) -> Handler(state) {
  handler(new(directory))
}

pub fn handler(config: Config) -> Handler(state) {
  fn(req: Request, ctx: Context(state)) {
    // A route without the wildcard, such as "/", serves the directory.
    let wanted = context.param(ctx, config.param) |> result.unwrap("")
    case safe_path(wanted) {
      Error(Nil) -> reply.not_found()
      Ok(relative) -> {
        let path = case relative {
          "" -> config.directory
          _ -> config.directory <> "/" <> relative
        }
        case file_info(path), indexed(config, path) {
          Ok(_), _ -> serve(req, config, path, config.cache_control)
          _, Ok(index) ->
            case string.ends_with(req.path, "/") {
              True -> serve(req, config, index, "no-cache")
              False -> slash(req)
            }
          _, _ ->
            case config.fallback, wants_html(req) {
              Some(file), True ->
                serve(req, config, config.directory <> "/" <> file, "no-cache")
              _, _ -> reply.not_found()
            }
        }
      }
    }
  }
}

/// The directory's `index.html`, when it has one and indexes are on.
fn indexed(config: Config, path: String) -> Result(String, Nil) {
  let index = path <> "/index.html"
  case config.index, file_info(index) {
    True, Ok(_) -> Ok(index)
    _, _ -> Error(Nil)
  }
}

/// A permanent redirect to the same path with a trailing slash.
fn slash(req: Request) -> Response {
  let location = case req.query {
    Some(query) -> req.path <> "/?" <> query
    None -> req.path <> "/"
  }
  reply.empty(301) |> response.set_header("location", location)
}

/// Whether the request is a page load rather than a fetch for an asset.
fn wants_html(req: Request) -> Bool {
  case request.get_header(req, "accept") {
    Ok(accept) -> string.contains(accept, "text/html")
    Error(Nil) -> False
  }
}

/// The `priv` directory of the OTP application `name`, where `gleam`
/// packages ship their static files.
pub fn priv(name: String) -> Result(String, Nil) {
  priv_dir(name)
}

fn serve(
  req: Request,
  config: Config,
  path: String,
  cache_control: String,
) -> Response {
  let #(file_path, encoding) = variant(req, config, path)
  let media_type = content_type(path)
  case file_info(file_path) {
    Ok(#(size, mtime)) -> {
      let suffix = case encoding {
        Ok(encoding) -> "-" <> encoding
        Error(Nil) -> ""
      }
      let etag =
        "\""
        <> int.to_base16(size)
        <> "-"
        <> int.to_base16(mtime)
        <> suffix
        <> "\""
      let last_modified = http_date(mtime)
      let file = fn(status, offset, length) {
        response.new(status)
        |> response.set_body(reply.File(path: file_path, offset:, length:))
        |> response.set_header("content-type", media_type)
      }
      case
        negotiate.none_match(request.get_header(req, "if-none-match"), etag),
        wanted_range(req, etag, last_modified, size)
      {
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
        False, Parts(ranges) -> multipart(file_path, media_type, size, ranges)
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
      |> response.set_header("cache-control", cache_control)
      |> encoded(encoding, config.precompressed)
    }
    Error(Nil) -> reply.not_found()
  }
}

/// The file to send, and its `content-encoding` when it is a compressed
/// copy. Brotli is preferred to gzip.
fn variant(
  req: Request,
  config: Config,
  path: String,
) -> #(String, Result(String, Nil)) {
  let accepted = request.get_header(req, "accept-encoding")
  case config.precompressed {
    False -> #(path, Error(Nil))
    True ->
      [#("br", ".br"), #("gzip", ".gz")]
      |> list.find_map(fn(candidate) {
        let #(encoding, extension) = candidate
        case negotiate.accepts_encoding(accepted, encoding) {
          True ->
            case file_info(path <> extension) {
              Ok(_) -> Ok(#(path <> extension, Ok(encoding)))
              Error(Nil) -> Error(Nil)
            }
          False -> Error(Nil)
        }
      })
      |> result.unwrap(#(path, Error(Nil)))
  }
}

fn encoded(
  res: Response,
  encoding: Result(String, Nil),
  precompressed: Bool,
) -> Response {
  let res = case encoding {
    Ok(encoding) -> response.set_header(res, "content-encoding", encoding)
    Error(Nil) -> res
  }
  case precompressed {
    True -> response.set_header(res, "vary", "accept-encoding")
    False -> res
  }
}

pub type Range {
  Whole
  /// Bytes `first` to `last`, inclusive.
  Part(first: Int, last: Int)
  /// Several ranges, in the order asked for, as `#(first, last)`.
  Parts(List(#(Int, Int)))
  Unsatisfiable
}

/// More ranges than this, or overlapping ones, get the whole file: they
/// only make a response bigger than the file itself.
const max_ranges = 16

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

/// A `range` header against a file of `size` bytes. A malformed header is
/// ignored (the whole file), ranges outside the file are dropped, and
/// `Unsatisfiable` means none were left.
pub fn parse_range(header: String, size: Int) -> Range {
  case string.trim(header) {
    "bytes=" <> spec -> {
      let specs = string.split(spec, ",")
      let parsed = list.map(specs, parse_spec(_, size))
      case list.length(specs) > max_ranges, list.all(parsed, result.is_ok) {
        True, _ | _, False -> Whole
        False, True -> {
          let ranges =
            list.filter_map(parsed, fn(parsed) {
              case parsed {
                Ok(Some(range)) -> Ok(range)
                _ -> Error(Nil)
              }
            })
          case ranges {
            [] -> Unsatisfiable
            [#(first, last)] -> Part(first, last)
            ranges ->
              case overlapping(ranges) {
                True -> Whole
                False -> Parts(ranges)
              }
          }
        }
      }
    }
    _ -> Whole
  }
}

/// One `first-last`, `first-` or `-suffix`: `Error` when malformed, `None`
/// when it lies outside the file.
fn parse_spec(spec: String, size: Int) -> Result(Option(#(Int, Int)), Nil) {
  case string.split_once(string.trim(spec), "-") {
    Ok(#("", n)) ->
      case int.parse(n) {
        Ok(n) if n > 0 && size > 0 -> Ok(Some(#(int.max(size - n, 0), size - 1)))
        Ok(_) -> Ok(None)
        Error(Nil) -> Error(Nil)
      }
    Ok(#(first, last)) ->
      case int.parse(first), last {
        Ok(first), _ if first < 0 -> Error(Nil)
        Ok(first), "" if first >= size -> Ok(None)
        Ok(first), "" -> Ok(Some(#(first, size - 1)))
        Ok(first), last ->
          case int.parse(last) {
            Ok(last) if last < first -> Error(Nil)
            Ok(_) if first >= size -> Ok(None)
            Ok(last) -> Ok(Some(#(first, int.min(last, size - 1))))
            Error(Nil) -> Error(Nil)
          }
        Error(Nil), _ -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
}

fn overlapping(ranges: List(#(Int, Int))) -> Bool {
  let sorted = list.sort(ranges, fn(a, b) { int.compare(a.0, b.0) })
  list.window_by_2(sorted) |> list.any(fn(pair) { pair.1.0 <= pair.0.1 })
}

/// A `206` whose body is each range as its own part, with its own
/// `content-range`.
fn multipart(
  path: String,
  media_type: String,
  size: Int,
  ranges: List(#(Int, Int)),
) -> Response {
  let boundary = random_boundary()
  let size_text = int.to_string(size)
  let segments =
    list.flat_map(ranges, fn(range) {
      let #(first, last) = range
      [
        reply.Data(bytes_tree.from_string(
          "--"
          <> boundary
          <> "\r\ncontent-type: "
          <> media_type
          <> "\r\ncontent-range: bytes "
          <> int.to_string(first)
          <> "-"
          <> int.to_string(last)
          <> "/"
          <> size_text
          <> "\r\n\r\n",
        )),
        reply.FileRange(path:, offset: first, length: last - first + 1),
        reply.Data(bytes_tree.from_string("\r\n")),
      ]
    })
  response.new(206)
  |> response.set_body(
    reply.Segments(
      list.append(segments, [
        reply.Data(bytes_tree.from_string("--" <> boundary <> "--\r\n")),
      ]),
    ),
  )
  |> response.set_header(
    "content-type",
    "multipart/byteranges; boundary=" <> boundary,
  )
}

fn random_boundary() -> String {
  crypto.strong_random_bytes(12)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// The wildcard's value as a relative path (`""` for the directory itself),
/// or `Error` if it could leave the directory or names a dotfile.
fn safe_path(path: String) -> Result(String, Nil) {
  let segments = string.split(path, "/") |> list.filter(fn(s) { s != "" })
  let unsafe =
    list.any(segments, fn(segment) {
      string.starts_with(segment, ".")
      || string.contains(segment, "\\")
      || string.contains(segment, "\u{0}")
    })
  case unsafe {
    True -> Error(Nil)
    False -> Ok(string.join(segments, "/"))
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

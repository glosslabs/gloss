//// Compress responses with gzip for clients that accept it.
////
//// ```gleam
//// server.new(routes(), state)
//// |> server.with(compress.gzip)
//// ```
////
//// JSON, text, byte and streamed bodies are compressed when the client's
//// `accept-encoding` allows gzip and the `content-type` is one that
//// compresses well (text, JSON, JavaScript, XML, SVG, WebAssembly, and
//// server-sent events). Bodies smaller than `min_bytes` (1 KiB by default)
//// are left alone, as gzip would make them bigger. Streams are compressed
//// chunk by chunk, each flushed at once, so server-sent events still arrive
//// as they are sent.
////
//// Files and partial responses are not compressed on the fly; serve
//// pre-compressed copies with `static.precompressed` instead. Responses
//// that already have a `content-encoding` are left as they are.
////
//// Compressible responses get `vary: accept-encoding`, so caches keep the
//// compressed and plain versions apart, and a compressed response's `etag`
//// gains a `-gzip` suffix.

import gleam/bytes_tree.{type BytesTree}
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gloss/http/context.{type Context, type Handler, type Middleware}
import gloss/http/reply.{type Request, type Response}
import gloss/internal/http_reply_negotiate as negotiate

pub opaque type Config {
  Config(min_bytes: Int)
}

pub fn new() -> Config {
  Config(min_bytes: 1024)
}

/// The smallest body worth compressing, in bytes.
pub fn min_bytes(_config: Config, bytes: Int) -> Config {
  Config(min_bytes: bytes)
}

/// `middleware(new())`.
pub fn gzip(next: Handler(state)) -> Handler(state) {
  middleware(new())(next)
}

pub fn middleware(config: Config) -> Middleware(state) {
  fn(next: Handler(state)) {
    fn(req: Request, ctx: Context(state)) {
      compress(config, req, next(req, ctx))
    }
  }
}

fn compress(config: Config, req: Request, res: Response) -> Response {
  let content_type =
    response.get_header(res, "content-type") |> result.unwrap("")
  let encoded = result.is_ok(response.get_header(res, "content-encoding"))
  case encoded || !compressible(content_type) || res.status == 206 {
    True -> res
    False -> {
      let res = vary(res)
      case
        negotiate.accepts_encoding(
          request.get_header(req, "accept-encoding"),
          "gzip",
        )
      {
        False -> res
        True ->
          case body_bytes(res.body) {
            Ok(bytes) ->
              case bytes_tree.byte_size(bytes) >= config.min_bytes {
                True ->
                  res
                  |> response.set_body(
                    reply.Bytes(bytes_tree.from_bit_array(gzip_bytes(bytes))),
                  )
                  |> encoded_as_gzip
                False -> res
              }
            Error(Nil) ->
              case res.body {
                reply.Stream(producer) ->
                  res
                  |> response.set_body(reply.Stream(gzip_stream(producer)))
                  |> encoded_as_gzip
                _ -> res
              }
          }
      }
    }
  }
}

/// The body as bytes, for bodies held in memory.
fn body_bytes(body: reply.Body) -> Result(BytesTree, Nil) {
  case body {
    reply.Json(json) ->
      Ok(bytes_tree.from_string_tree(json.to_string_tree(json)))
    reply.Text(text) -> Ok(bytes_tree.from_string(text))
    reply.Bytes(bytes) -> Ok(bytes)
    _ -> Error(Nil)
  }
}

fn encoded_as_gzip(res: Response) -> Response {
  let res = response.set_header(res, "content-encoding", "gzip")
  case response.get_header(res, "etag") {
    Ok(etag) ->
      case string.ends_with(etag, "\"") {
        True ->
          response.set_header(
            res,
            "etag",
            string.drop_end(etag, 1) <> "-gzip\"",
          )
        False -> res
      }
    Error(Nil) -> res
  }
}

fn vary(res: Response) -> Response {
  case response.get_header(res, "vary") {
    Ok(existing) ->
      case string.contains(string.lowercase(existing), "accept-encoding") {
        True -> res
        False ->
          response.set_header(res, "vary", existing <> ", accept-encoding")
      }
    Error(Nil) -> response.set_header(res, "vary", "accept-encoding")
  }
}

fn gzip_stream(producer: fn(reply.Emit) -> Nil) -> fn(reply.Emit) -> Nil {
  fn(emit: reply.Emit) {
    let z = gzip_open()
    producer(fn(chunk) { emit(bytes_tree.from_bit_array(gzip_chunk(z, chunk))) })
    let _ = emit(bytes_tree.from_bit_array(gzip_finish(z)))
    Nil
  }
}

/// Whether a media type is worth compressing.
pub fn compressible(content_type: String) -> Bool {
  let media = case string.split(string.lowercase(content_type), ";") {
    [media, ..] -> string.trim(media)
    [] -> ""
  }
  string.starts_with(media, "text/")
  || string.ends_with(media, "+json")
  || string.ends_with(media, "+xml")
  || list.contains(
    [
      "application/json", "application/javascript", "application/xml",
      "application/wasm", "image/svg+xml",
    ],
    media,
  )
}

fn gzip_bytes(bytes: BytesTree) -> BitArray {
  gzip_all(bytes_tree.to_bit_array(bytes))
}

type Deflater

@external(erlang, "gloss@http@server_ffi", "gzip")
fn gzip_all(data: BitArray) -> BitArray

@external(erlang, "gloss@http@server_ffi", "gzip_open")
fn gzip_open() -> Deflater

@external(erlang, "gloss@http@server_ffi", "gzip_chunk")
fn gzip_chunk(z: Deflater, data: BytesTree) -> BitArray

@external(erlang, "gloss@http@server_ffi", "gzip_finish")
fn gzip_finish(z: Deflater) -> BitArray

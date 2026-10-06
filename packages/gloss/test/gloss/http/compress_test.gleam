import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import gloss/http/compress
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import gloss/internal/http_reply_negotiate as negotiate
import http_support.{header, request}

const long_text = "lorem ipsum dolor sit amet, "

fn big() -> String {
  string.repeat(long_text, 100)
}

fn routes() {
  router.new()
  |> router.with(compress.gzip)
  |> router.get("/json", fn(_, _) {
    reply.json(200, json.object([#("text", json.string(big()))]))
    |> response.set_header("etag", "\"v1\"")
  })
  |> router.get("/small", fn(_, _) { reply.text(200, "tiny") })
  |> router.get("/image", fn(_, _) {
    reply.bytes(200, "image/png", bytes_tree.from_string(big()))
  })
  |> router.get("/already", fn(_, _) {
    reply.text(200, big()) |> response.set_header("content-encoding", "br")
  })
  |> router.get("/stream", fn(_, _) {
    reply.stream(200, "text/plain", fn(emit) {
      list.each(["one ", "two ", "three"], fn(piece) {
        let _ = emit(bytes_tree.from_string(piece))
        Nil
      })
    })
  })
}

fn get(path: String, accept: String) {
  server.handle(
    server.new(routes(), Nil),
    request(http.Get, path) |> request.set_header("accept-encoding", accept),
  )
}

fn gunzipped(res: response.Response(bytes_tree.BytesTree)) -> String {
  let assert Ok(plain) = gunzip(bytes_tree.to_bit_array(res.body))
  let assert Ok(text) = bit_array.to_string(plain)
  text
}

pub fn compresses_large_text_test() {
  let res = get("/json", "br;q=1.0, gzip;q=0.8")
  header(res, "content-encoding") |> should.equal("gzip")
  header(res, "vary") |> should.equal("accept-encoding")
  header(res, "etag") |> should.equal("\"v1-gzip\"")
  gunzipped(res)
  |> should.equal(json.to_string(json.object([#("text", json.string(big()))])))
  { bytes_tree.byte_size(res.body) < string.byte_size(big()) }
  |> should.be_true
}

pub fn leaves_some_responses_alone_test() {
  // Too small to gain anything, but still varies by encoding.
  let res = get("/small", "gzip")
  header(res, "content-encoding") |> should.equal("")
  header(res, "vary") |> should.equal("accept-encoding")
  // Not asked for, or refused.
  header(get("/json", ""), "content-encoding") |> should.equal("")
  header(get("/json", "gzip;q=0"), "content-encoding") |> should.equal("")
  // Not worth compressing.
  let res = get("/image", "gzip")
  header(res, "content-encoding") |> should.equal("")
  header(res, "vary") |> should.equal("")
  // Already encoded.
  header(get("/already", "gzip"), "content-encoding") |> should.equal("br")
}

pub fn compresses_streams_test() {
  let res = get("/stream", "gzip")
  header(res, "content-encoding") |> should.equal("gzip")
  gunzipped(res) |> should.equal("one two three")
}

pub fn stream_chunks_are_decodable_as_they_arrive_test() {
  let routes =
    router.new()
    |> router.with(compress.gzip)
    |> router.get("/slow", fn(_, _) {
      reply.stream(200, "text/event-stream", fn(emit) {
        let _ = emit(bytes_tree.from_string("data: first\n\n"))
        // The client decodes the first event before this one is sent.
        process.sleep(2000)
        let _ = emit(bytes_tree.from_string("data: second\n\n"))
        Nil
      })
    })
  let assert Ok(srv) = server.new(routes, Nil) |> server.port(0) |> server.start
  first_chunk_text(server.port_of(srv), "/slow")
  |> should.equal(<<"data: first\n\n">>)
  let _ = server.shutdown(srv)
}

pub fn accepts_encoding_test() {
  negotiate.accepts_encoding(Ok("gzip, deflate"), "gzip") |> should.be_true
  negotiate.accepts_encoding(Ok("*"), "gzip") |> should.be_true
  negotiate.accepts_encoding(Ok("*, gzip;q=0"), "gzip") |> should.be_false
  negotiate.accepts_encoding(Ok("br"), "gzip") |> should.be_false
  negotiate.accepts_encoding(Error(Nil), "gzip") |> should.be_false
}

pub fn compressible_test() {
  compress.compressible("application/json; charset=utf-8") |> should.be_true
  compress.compressible("application/vnd.api+json") |> should.be_true
  compress.compressible("text/event-stream") |> should.be_true
  compress.compressible("image/svg+xml") |> should.be_true
  compress.compressible("image/png") |> should.be_false
  compress.compressible("video/mp4") |> should.be_false
}

@external(erlang, "compress_test_ffi", "first_chunk_text")
fn first_chunk_text(port: Int, path: String) -> BitArray

@external(erlang, "compress_test_ffi", "gunzip")
fn gunzip(data: BitArray) -> Result(BitArray, Nil)

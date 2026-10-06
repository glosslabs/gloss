import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import gloss/http/body
import gloss/http/reply
import gloss/http/router
import gloss/http/server.{type Server}

type Socket

type Reply =
  #(Int, List(#(String, String)), BitArray)

fn routes() {
  router.new()
  // Counts the bytes without holding them.
  |> router.post("/upload", fn(req, _) {
    use result <- body.stream(req, fn(_chunk) { Ok(Nil) })
    case result {
      Ok(bytes) -> reply.text(201, int.to_string(bytes))
      Error(_) -> reply.internal_error()
    }
  })
  // Stops after 10 bytes.
  |> router.post("/limited", fn(req, _) {
    use result <- body.stream(req, fn(chunk) {
      case bit_array.byte_size(chunk) > 10 {
        True -> Error("too big")
        False -> Ok(Nil)
      }
    })
    case result {
      Ok(bytes) -> reply.text(201, int.to_string(bytes))
      Error(body.Stopped(reason)) -> reply.error(413, reason)
      Error(body.Failed(error)) -> body.error_response(error)
    }
  })
  |> router.post("/echo", fn(req, _) {
    use text <- body.text(req)
    reply.text(200, text)
  })
  // Refuses without reading.
  |> router.post("/private", fn(_, _) { reply.unauthorized() })
  // Reads twice, then streams what was read.
  |> router.post("/twice", fn(req, _) {
    use first <- body.text(req)
    use second <- body.text(req)
    use streamed <- body.stream(req, fn(_) { Ok(Nil) })
    let assert Ok(bytes) = streamed
    reply.text(200, first <> "|" <> second <> "|" <> int.to_string(bytes))
  })
  // Streams, then tries a buffered read.
  |> router.post("/after", fn(req, _) {
    use _ <- body.stream(req, fn(_) { Ok(Nil) })
    use _ <- body.bits(req)
    reply.text(200, "unreachable")
  })
}

fn start() -> #(Server, Int) {
  let assert Ok(srv) =
    server.new(routes(), Nil)
    |> server.port(0)
    |> server.max_body(1024)
    |> server.start
  #(srv, server.port_of(srv))
}

fn post(path: String, body: String) -> String {
  "POST "
  <> path
  <> " HTTP/1.1\r\ncontent-length: "
  <> int.to_string(string.byte_size(body))
  <> "\r\n\r\n"
  <> body
}

pub fn large_uploads_stream_past_max_body_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  let big = string.repeat("x", 300_000)
  send(socket, post("/upload", big))
  let assert Ok(#(201, _, count)) = read_response(socket, 2000)
  count |> should.equal(<<"300000">>)
  // Fully read, so the connection is reused.
  send(socket, post("/upload", "abc"))
  let assert Ok(#(201, _, count)) = read_response(socket, 1000)
  count |> should.equal(<<"3">>)
  let _ = server.shutdown(srv)
}

pub fn chunked_uploads_stream_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  let chunk = string.repeat("y", 2000)
  let chunks = list.repeat("7d0\r\n" <> chunk <> "\r\n", 3) |> string.concat
  send(
    socket,
    "POST /upload HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n"
      <> chunks
      <> "0\r\n\r\n",
  )
  let assert Ok(#(201, _, count)) = read_response(socket, 2000)
  count |> should.equal(<<"6000">>)
  let _ = server.shutdown(srv)
}

pub fn buffered_reads_still_respect_max_body_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  send(socket, post("/twice", string.repeat("z", 2000)))
  let assert Ok(#(413, _, _)) = read_response(socket, 1000)
  closed(socket, 1000) |> should.be_true
  let _ = server.shutdown(srv)
}

pub fn stopping_a_stream_closes_the_connection_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  send(socket, post("/limited", string.repeat("q", 100_000)))
  let assert Ok(#(413, _, body)) = read_response(socket, 1000)
  body |> should.equal(<<"{\"error\":\"too big\"}">>)
  closed(socket, 1000) |> should.be_true
  let _ = server.shutdown(srv)
}

pub fn rejecting_without_reading_skips_100_continue_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  send(
    socket,
    "POST /private HTTP/1.1\r\ncontent-length: 5\r\nexpect: 100-continue\r\n\r\n",
  )
  // The final answer comes first, with no 100 Continue before it.
  let assert Ok(#(401, headers, _)) = read_response(socket, 1000)
  list.key_find(headers, "connection") |> should.equal(Ok("close"))
  closed(socket, 1000) |> should.be_true
  let _ = server.shutdown(srv)
}

pub fn reading_twice_gives_the_same_bytes_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  send(socket, post("/twice", "hello"))
  let assert Ok(#(200, _, body)) = read_response(socket, 1000)
  body |> should.equal(<<"hello|hello|5">>)
  let _ = server.shutdown(srv)
}

pub fn reading_after_streaming_fails_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  send(socket, post("/after", "hello"))
  let assert Ok(#(500, _, _)) = read_response(socket, 1000)
  let _ = server.shutdown(srv)
}

fn post_gzip(path: String, encoding: String, payload: BitArray) -> BitArray {
  <<
    "POST ":utf8,
    path:utf8,
    " HTTP/1.1\r\ncontent-encoding: ":utf8,
    encoding:utf8,
    "\r\ncontent-length: ":utf8,
    int.to_string(bit_array.byte_size(payload)):utf8,
    "\r\n\r\n":utf8,
    payload:bits,
  >>
}

pub fn gzipped_bodies_are_inflated_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  send_bits(socket, post_gzip("/echo", "gzip", gzip(<<"hello world":utf8>>)))
  let assert Ok(#(200, _, body)) = read_response(socket, 1000)
  body |> should.equal(<<"hello world">>)
  // Streams see the inflated bytes, past max_body.
  let big = gzip(bit_array.from_string(string.repeat("x", 300_000)))
  send_bits(socket, post_gzip("/upload", "gzip", big))
  let assert Ok(#(201, _, count)) = read_response(socket, 2000)
  count |> should.equal(<<"300000">>)
  let _ = server.shutdown(srv)
}

pub fn gzip_bombs_hit_max_body_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  // 10 MB of zeros, a few kilobytes compressed; max_body is 1 KiB.
  let bomb = gzip(<<0:size(80_000_000)>>)
  { bit_array.byte_size(bomb) < 20_000 } |> should.be_true
  send_bits(socket, post_gzip("/echo", "gzip", bomb))
  let assert Ok(#(413, _, _)) = read_response(socket, 2000)
  let _ = server.shutdown(srv)
}

pub fn bad_gzip_is_a_400_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  send_bits(socket, post_gzip("/echo", "gzip", <<"not gzip at all":utf8>>))
  let assert Ok(#(400, _, _)) = read_response(socket, 1000)

  let assert Ok(socket) = connect(port)
  let whole = gzip(<<"hello world":utf8>>)
  let truncated = slice(whole, bit_array.byte_size(whole) - 6)
  send_bits(socket, post_gzip("/echo", "gzip", truncated))
  let assert Ok(#(400, _, body)) = read_response(socket, 1000)
  body |> should.equal(<<"{\"error\":\"truncated gzip body\"}">>)
  let _ = server.shutdown(srv)
}

pub fn unsupported_encodings_are_a_415_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  send_bits(socket, post_gzip("/echo", "br", <<"x":utf8>>))
  let assert Ok(#(415, _, _)) = read_response(socket, 1000)
  let _ = server.shutdown(srv)
}

fn slice(bits: BitArray, length: Int) -> BitArray {
  let assert Ok(part) = bit_array.slice(bits, 0, length)
  part
}

@external(erlang, "compress_test_ffi", "gzip")
fn gzip(data: BitArray) -> BitArray

@external(erlang, "http_client_ffi", "send")
fn send_bits(socket: Socket, data: BitArray) -> Nil

@external(erlang, "http_client_ffi", "connect")
fn connect(port: Int) -> Result(Socket, Nil)

@external(erlang, "http_client_ffi", "send")
fn send(socket: Socket, data: String) -> Nil

@external(erlang, "http_client_ffi", "read_response")
fn read_response(socket: Socket, timeout: Int) -> Result(Reply, Nil)

@external(erlang, "http_client_ffi", "is_closed")
fn closed(socket: Socket, timeout: Int) -> Bool

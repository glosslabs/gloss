import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/response
import gleam/option.{None, Some}
import gleeunit/should
import gloss/internal/http_server_http1.{Head} as http1

fn head(version: #(Int, Int), headers: List(#(String, String))) {
  Head(method: http.Get, target: "/", version:, headers:)
}

pub fn body_framing_test() {
  let framing = fn(headers) { http1.body_framing(head(#(1, 1), headers)) }
  framing([]) |> should.equal(Ok(http1.Length(0)))
  framing([#("content-length", "12")]) |> should.equal(Ok(http1.Length(12)))
  framing([#("content-length", "5"), #("content-length", "5")])
  |> should.equal(Ok(http1.Length(5)))
  framing([#("content-length", "5"), #("content-length", "6")])
  |> should.equal(Error(http1.InvalidContentLength))
  framing([#("content-length", "-1")])
  |> should.equal(Error(http1.InvalidContentLength))
  framing([#("transfer-encoding", "Chunked")])
  |> should.equal(Ok(http1.Chunked))
  framing([#("transfer-encoding", "gzip, chunked")])
  |> should.equal(Error(http1.UnsupportedTransferEncoding))
  framing([#("transfer-encoding", "chunked"), #("content-length", "3")])
  |> should.equal(Error(http1.ConflictingFraming))
}

pub fn chunk_size_test() {
  http1.chunk_size("1a") |> should.equal(Ok(26))
  http1.chunk_size("1A;name=value") |> should.equal(Ok(26))
  http1.chunk_size("0") |> should.equal(Ok(0))
  http1.chunk_size("") |> should.equal(Error(Nil))
  http1.chunk_size("zz") |> should.equal(Error(Nil))
  http1.chunk_size("ffffffffffffffff") |> should.equal(Error(Nil))
}

pub fn chunk_test() {
  http1.chunk(bytes_tree.from_string("hello world, again"))
  |> to_string
  |> should.equal("12\r\nhello world, again\r\n")
}

pub fn keep_alive_test() {
  http1.keep_alive(head(#(1, 1), [])) |> should.be_true
  http1.keep_alive(head(#(1, 1), [#("connection", "Close")])) |> should.be_false
  http1.keep_alive(head(#(1, 0), [])) |> should.be_false
  http1.keep_alive(head(#(1, 0), [#("connection", "keep-alive, Upgrade")]))
  |> should.be_true
}

pub fn expects_continue_test() {
  http1.expects_continue(head(#(1, 1), [#("expect", "100-continue")]))
  |> should.be_true
  http1.expects_continue(head(#(1, 0), [#("expect", "100-continue")]))
  |> should.be_false
}

pub fn to_request_test() {
  let req =
    http1.to_request(
      Head(
        method: http.Post,
        target: "/notes?page=2",
        version: #(1, 1),
        headers: [#("host", "example.com:8080")],
      ),
      <<"hi">>,
    )
  req.method |> should.equal(http.Post)
  req.path |> should.equal("/notes")
  req.query |> should.equal(Some("page=2"))
  req.host |> should.equal("example.com")
  req.port |> should.equal(Some(8080))
  req.body |> should.equal(<<"hi">>)

  let req = http1.to_request(head(#(1, 1), [#("host", "example.com")]), <<>>)
  req.query |> should.equal(None)
  req.port |> should.equal(None)
}

pub fn encode_test() {
  let wire =
    http1.encode(
      text_response(201, "made"),
      keep_alive: True,
      head_request: False,
      date: "D",
    )
  to_string(wire)
  |> should.equal(
    "HTTP/1.1 201 Created\r\ncontent-length: 4\r\ndate: D\r\nconnection: keep-alive\r\ncontent-type: text/plain; charset=utf-8\r\n\r\nmade",
  )
}

pub fn encode_head_request_omits_body_test() {
  let wire =
    http1.encode(
      text_response(200, "abc"),
      keep_alive: False,
      head_request: True,
      date: "D",
    )
  to_string(wire)
  |> should.equal(
    "HTTP/1.1 200 OK\r\ncontent-length: 3\r\ndate: D\r\nconnection: close\r\ncontent-type: text/plain; charset=utf-8\r\n\r\n",
  )
}

fn to_string(tree: bytes_tree.BytesTree) -> String {
  let assert Ok(s) = tree |> bytes_tree.to_bit_array |> bit_array.to_string
  s
}

fn text_response(status: Int, body: String) {
  response.new(status)
  |> response.set_body(bytes_tree.from_string(body))
  |> response.set_header("content-type", "text/plain; charset=utf-8")
}

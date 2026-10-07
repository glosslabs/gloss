import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import gloss/http/body
import gloss/http/multipart
import gloss/http/reply
import gloss/http/router
import gloss/http/server.{type Server}
import http_support.{rendered_body, request}

/// Describes the form it was sent.
fn describe(form: body.Form) -> String {
  let values = list.map(form.values, fn(pair) { pair.0 <> "=" <> pair.1 })
  let files =
    list.map(form.files, fn(pair) {
      let #(name, file) = pair
      name
      <> ":"
      <> file.filename
      <> ":"
      <> file.content_type
      <> ":"
      <> int.to_string(bit_array.byte_size(file.data))
    })
  string.join(list.append(values, files), ",")
}

fn routes() {
  router.new()
  |> router.post("/form", fn(req, _) {
    use form <- body.form(req)
    reply.text(200, describe(form))
  })
  // Streams each part, counting its bytes without keeping them.
  |> router.post("/stream", fn(req, _) {
    use result <- multipart.fold(req, [], fn(seen, event) {
      case event, seen {
        multipart.Start(part), _ -> Ok([#(part.name, 0), ..seen])
        multipart.Data(data), [#(name, size), ..rest] ->
          Ok([#(name, size + bit_array.byte_size(data)), ..rest])
        multipart.End, _ -> Ok(seen)
        multipart.Data(_), [] -> Error("data before a part")
      }
    })
    case result {
      Ok(seen) ->
        list.reverse(seen)
        |> list.map(fn(pair) { pair.0 <> "=" <> int.to_string(pair.1) })
        |> string.join(",")
        |> reply.text(200, _)
      Error(error) -> multipart.error_response(error)
    }
  })
  |> router.post("/sum", fn(req, _) {
    use result <- body.fold(req, 0, fn(total, chunk) {
      Ok(total + bit_array.byte_size(chunk))
    })
    let assert Ok(total) = result
    reply.text(200, int.to_string(total))
  })
}

fn post(content_type: String, payload: String) {
  server.handle(
    server.new(routes(), Nil),
    request(http.Post, "/form")
      |> request.set_header("content-type", content_type)
      |> request.set_body(body.from_string(payload)),
  )
}

const multipart_body =
  "--B\r
Content-Disposition: form-data; name=\"title\"\r
\r
My file\r
--B\r
Content-Disposition: form-data; name=\"tag\"\r
\r
a\r
--B\r
Content-Disposition: form-data; name=\"tag\"\r
\r
b\r
--B\r
Content-Disposition: form-data; name=\"upload\"; filename=\"notes.txt\"\r
Content-Type: text/plain\r
\r
hello there\r
--B--\r
"

pub fn urlencoded_form_test() {
  let res =
    post("application/x-www-form-urlencoded", "name=Ada+L&city=Z%C3%BCrich&a=")
  res.status |> should.equal(200)
  rendered_body(res) |> should.equal("name=Ada L,city=Zürich,a=")
}

pub fn multipart_form_test() {
  let res = post("multipart/form-data; boundary=B", multipart_body)
  res.status |> should.equal(200)
  rendered_body(res)
  |> should.equal("title=My file,tag=a,tag=b,upload:notes.txt:text/plain:11")
}

pub fn form_errors_test() {
  post("application/json", "{}").status |> should.equal(415)
  post("multipart/form-data", multipart_body).status |> should.equal(400)
  post("multipart/form-data; boundary=B", "--B\r\nnot headers").status
  |> should.equal(400)
  // A text field must be UTF-8; a file needn't be.
  let bad = "--B\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n"
  server.handle(
    server.new(routes(), Nil),
    request(http.Post, "/form")
      |> request.set_header("content-type", "multipart/form-data; boundary=B")
      |> request.set_body(
        body.from_bits(<<bad:utf8, 0xff, "\r\n--B--\r\n":utf8>>),
      ),
  ).status
  |> should.equal(400)
}

pub fn fold_test() {
  server.handle(
    server.new(routes(), Nil),
    request(http.Post, "/sum") |> request.set_body(body.from_string("12345")),
  )
  |> rendered_body
  |> should.equal("5")
}

fn start() -> #(Server, Int) {
  let assert Ok(srv) =
    server.new(routes(), Nil)
    |> server.port(0)
    |> server.max_body(1024)
    |> server.start
  #(srv, server.port_of(srv))
}

fn upload(path: String, payload: String) -> String {
  "POST "
  <> path
  <> " HTTP/1.1\r\nhost: localhost\r\ncontent-type: multipart/form-data; boundary=B\r\ncontent-length: "
  <> int.to_string(string.byte_size(payload))
  <> "\r\n\r\n"
  <> payload
}

fn big_upload() -> String {
  "--B\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nhi\r\n"
  <> "--B\r\nContent-Disposition: form-data; name=\"video\"; filename=\"v.mp4\"\r\nContent-Type: video/mp4\r\n\r\n"
  <> string.repeat("v", 300_000)
  <> "\r\n--B--\r\n"
}

pub fn streaming_uploads_past_max_body_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  send(socket, upload("/stream", big_upload()))
  let assert Ok(#(200, _, body)) = read_response(socket, 2000)
  body |> should.equal(<<"note=2,video=300000">>)
  let _ = server.shutdown(srv)
}

pub fn buffered_forms_respect_max_body_test() {
  let #(srv, port) = start()
  let assert Ok(socket) = connect(port)
  send(socket, upload("/form", big_upload()))
  let assert Ok(#(413, _, _)) = read_response(socket, 2000)
  let _ = server.shutdown(srv)
}

pub fn streaming_needs_multipart_test() {
  server.handle(
    server.new(routes(), Nil),
    request(http.Post, "/stream")
      |> request.set_header("content-type", "text/plain")
      |> request.set_body(body.from_string("x")),
  ).status
  |> should.equal(415)
}

type Socket

@external(erlang, "http_client_ffi", "connect")
fn connect(port: Int) -> Result(Socket, Nil)

@external(erlang, "http_client_ffi", "send")
fn send(socket: Socket, data: String) -> Nil

@external(erlang, "http_client_ffi", "read_response")
fn read_response(
  socket: Socket,
  timeout: Int,
) -> Result(#(Int, List(#(String, String)), BitArray), Nil)

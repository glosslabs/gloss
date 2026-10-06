import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleeunit/should
import gloss/http/router
import gloss/http/server
import gloss/http/static
import http_support.{header, rendered_body, request}

/// A fresh directory under build/ with a few files in it.
fn site() -> String {
  let dir =
    "build/test-static/"
    <> int.to_string(system_time())
    <> "-"
    <> int.to_string(unique())
  write(dir <> "/app.css", "body{}")
  write(dir <> "/js/app.js", "let x = 1")
  write(dir <> "/.env", "SECRET=1")
  write(dir <> "/sub/index.html", "<p>hi</p>")
  write(dir <> "/../secret.txt", "outside")
  dir
}

fn builder(config: static.Config) {
  router.new()
  |> router.get("/assets/*path", static.handler(config))
  |> server.new(Nil)
}

fn get(dir: String, path: String) {
  server.handle(builder(static.new(dir)), request(http.Get, path))
}

pub fn serves_files_with_types_test() {
  let dir = site()
  let res = get(dir, "/assets/app.css")
  res.status |> should.equal(200)
  rendered_body(res) |> should.equal("body{}")
  header(res, "content-type") |> should.equal("text/css; charset=utf-8")
  header(res, "cache-control") |> should.equal("no-cache")

  let res = get(dir, "/assets/js/app.js")
  rendered_body(res) |> should.equal("let x = 1")
  header(res, "content-type")
  |> should.equal("text/javascript; charset=utf-8")
}

pub fn etag_revalidation_test() {
  let dir = site()
  let etag = header(get(dir, "/assets/app.css"), "etag")
  let res =
    server.handle(
      builder(static.new(dir)),
      request(http.Get, "/assets/app.css")
        |> request.set_header("if-none-match", "W/\"other\", " <> etag),
    )
  res.status |> should.equal(304)
  rendered_body(res) |> should.equal("")
  header(res, "etag") |> should.equal(etag)
}

pub fn unsafe_and_missing_paths_are_not_found_test() {
  let dir = site()
  [
    "/assets/..%2Fsecret.txt",
    "/assets/sub/..%2F..%2Fsecret.txt",
    "/assets/.env",
    "/assets/sub",
    "/assets/missing.css",
  ]
  |> list.each(fn(path) { get(dir, path).status |> should.equal(404) })
}

pub fn head_has_length_but_no_body_test() {
  let dir = site()
  let res =
    server.handle(
      builder(static.new(dir)),
      request(http.Head, "/assets/app.css"),
    )
  res.status |> should.equal(200)
  header(res, "content-type") |> should.equal("text/css; charset=utf-8")
}

pub fn custom_cache_control_test() {
  let dir = site()
  let config = static.new(dir) |> static.cache_control("public, max-age=60")
  server.handle(builder(config), request(http.Get, "/assets/app.css"))
  |> header("cache-control")
  |> should.equal("public, max-age=60")
}

pub fn parse_range_test() {
  let size = 100
  static.parse_range("bytes=0-9", size) |> should.equal(static.Part(0, 9))
  static.parse_range("bytes=90-", size) |> should.equal(static.Part(90, 99))
  static.parse_range("bytes=-10", size) |> should.equal(static.Part(90, 99))
  static.parse_range("bytes=-500", size) |> should.equal(static.Part(0, 99))
  static.parse_range("bytes=50-500", size) |> should.equal(static.Part(50, 99))
  static.parse_range("bytes=100-", size) |> should.equal(static.Unsatisfiable)
  static.parse_range("bytes=-0", size) |> should.equal(static.Unsatisfiable)
  static.parse_range("bytes=0-1, 5-6", size) |> should.equal(static.Whole)
  static.parse_range("bytes=9-0", size) |> should.equal(static.Whole)
  static.parse_range("items=0-1", size) |> should.equal(static.Whole)
  static.parse_range("bytes=0-", 0) |> should.equal(static.Unsatisfiable)
}

fn ranged(dir: String, range: String) {
  server.handle(
    builder(static.new(dir)),
    request(http.Get, "/assets/js/app.js") |> request.set_header("range", range),
  )
}

pub fn range_requests_test() {
  let dir = site()
  // "let x = 1" is 9 bytes.
  let res = ranged(dir, "bytes=4-6")
  res.status |> should.equal(206)
  rendered_body(res) |> should.equal("x =")
  header(res, "content-range") |> should.equal("bytes 4-6/9")
  header(res, "accept-ranges") |> should.equal("bytes")

  ranged(dir, "bytes=-1") |> rendered_body |> should.equal("1")

  let res = ranged(dir, "bytes=20-")
  res.status |> should.equal(416)
  header(res, "content-range") |> should.equal("bytes */9")

  ranged(dir, "bytes=0-1,3-4").status |> should.equal(200)
}

pub fn if_range_test() {
  let dir = site()
  let whole = get(dir, "/assets/js/app.js")
  let with_if_range = fn(validator) {
    server.handle(
      builder(static.new(dir)),
      request(http.Get, "/assets/js/app.js")
        |> request.set_header("range", "bytes=0-2")
        |> request.set_header("if-range", validator),
    ).status
  }
  with_if_range(header(whole, "etag")) |> should.equal(206)
  with_if_range(header(whole, "last-modified")) |> should.equal(206)
  with_if_range("\"stale\"") |> should.equal(200)
}

pub fn content_type_test() {
  static.content_type("a/b/logo.SVG") |> should.equal("image/svg+xml")
  static.content_type("Makefile") |> should.equal("application/octet-stream")
}

pub fn priv_test() {
  static.priv("gloss") |> should.be_ok
  static.priv("no_such_application_xyz") |> should.equal(Error(Nil))
}

pub fn sendfile_over_a_socket_test() {
  let dir = site()
  let assert Ok(srv) =
    builder(static.new(dir)) |> server.port(0) |> server.start
  let assert Ok(socket) = connect(server.port_of(srv))
  send(socket, "GET /assets/js/app.js HTTP/1.1\r\n\r\n")
  let assert Ok(#(status, _, body)) = read_response(socket, 1000)
  status |> should.equal(200)
  body |> should.equal(<<"let x = 1">>)
  // The connection stays usable after a sendfile.
  send(socket, "GET /assets/app.css HTTP/1.1\r\n\r\n")
  let assert Ok(#(_, _, body)) = read_response(socket, 1000)
  body |> should.equal(<<"body{}">>)
  // A range is sent from the right offset.
  send(socket, "GET /assets/js/app.js HTTP/1.1\r\nrange: bytes=4-\r\n\r\n")
  let assert Ok(#(status, _, body)) = read_response(socket, 1000)
  status |> should.equal(206)
  body |> should.equal(<<"x = 1">>)
  let _ = server.shutdown(srv)
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

@external(erlang, "static_test_ffi", "write")
fn write(path: String, contents: String) -> Nil

@external(erlang, "os", "system_time")
fn system_time() -> Int

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueOption)) -> Int

type UniqueOption {
  Positive
}

fn unique() -> Int {
  unique_integer([Positive])
}

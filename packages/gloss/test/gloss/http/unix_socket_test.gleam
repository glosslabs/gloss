import gleam/int
import gleeunit/should
import gloss/http/reply
import gloss/http/router
import gloss/http/server.{type Builder}

type Socket

/// A short path: Unix socket paths are limited to about 100 bytes.
fn path() -> String {
  "/tmp/gloss-test-" <> int.to_string(unique()) <> ".sock"
}

fn builder(path: String) -> Builder(Nil) {
  router.new()
  |> router.get("/", fn(_, ctx) { reply.text(200, ctx.client_ip) })
  |> server.new(Nil)
  |> server.bind_unix(path)
}

fn get(path: String, headers: String) {
  let assert Ok(socket) = connect_unix(path)
  send(socket, "GET / HTTP/1.1\r\nhost: localhost\r\n" <> headers <> "\r\n")
  let result = read_response(socket, 1000)
  close(socket)
  result
}

pub fn serves_over_a_unix_socket_test() {
  let path = path()
  let assert Ok(srv) = builder(path) |> server.start
  server.port_of(srv) |> should.equal(0)

  let assert Ok(#(200, _, body)) = get(path, "")
  body |> should.equal(<<"unix">>)

  // The proxy on the other end is trusted without trust_proxies.
  let assert Ok(#(200, _, body)) = get(path, "x-forwarded-for: 203.0.113.9\r\n")
  body |> should.equal(<<"203.0.113.9">>)

  let assert Ok(Nil) = server.shutdown(srv)
  exists(path) |> should.be_false
}

pub fn a_live_socket_is_not_taken_over_test() {
  let path = path()
  let assert Ok(srv) = builder(path) |> server.start
  let assert Error(server.Unavailable(_)) = builder(path) |> server.start
  // The first server is untouched.
  let assert Ok(#(200, _, _)) = get(path, "")
  let assert Ok(Nil) = server.shutdown(srv)
}

pub fn a_stale_socket_is_replaced_test() {
  let path = path()
  stale_socket(path)
  exists(path) |> should.be_true

  let assert Ok(srv) = builder(path) |> server.start
  let assert Ok(#(200, _, _)) = get(path, "")
  let assert Ok(Nil) = server.shutdown(srv)
}

pub fn a_file_that_is_not_a_socket_is_left_alone_test() {
  let path = path()
  make_file(path)
  let assert Error(server.Unavailable(_)) = builder(path) |> server.start
  exists(path) |> should.be_true
  delete(path)
}

@external(erlang, "http_client_ffi", "connect_unix")
fn connect_unix(path: String) -> Result(Socket, Nil)

@external(erlang, "http_client_ffi", "send")
fn send(socket: Socket, data: String) -> Nil

@external(erlang, "http_client_ffi", "close")
fn close(socket: Socket) -> Nil

@external(erlang, "http_client_ffi", "read_response")
fn read_response(
  socket: Socket,
  timeout: Int,
) -> Result(#(Int, List(#(String, String)), BitArray), Nil)

@external(erlang, "http_client_ffi", "make_file")
fn make_file(path: String) -> Nil

@external(erlang, "http_client_ffi", "stale_socket")
fn stale_socket(path: String) -> Nil

@external(erlang, "http_client_ffi", "exists")
fn exists(path: String) -> Bool

@external(erlang, "file", "delete")
fn delete(path: String) -> a

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueOption)) -> Int

type UniqueOption {
  Positive
}

fn unique() -> Int {
  unique_integer([Positive])
}

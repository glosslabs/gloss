import gleam/http
import gleam/http/request
import gleam/int
import gleam/option.{Some}
import gleeunit/should
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import http_support.{rendered_body, request}

/// Echoes what the handler sees.
fn routes() {
  router.new()
  |> router.get("/", fn(req, ctx) {
    let scheme = http.scheme_to_string(req.scheme)
    let port = case req.port {
      Some(port) -> ":" <> int.to_string(port)
      _ -> ""
    }
    reply.text(200, ctx.client_ip <> " " <> scheme <> "://" <> req.host <> port)
  })
}

fn forwarded_request() {
  // As the server builds it from a plain-HTTP connection.
  request(http.Get, "/")
  |> request.set_scheme(http.Http)
  |> request.set_header("x-forwarded-for", "203.0.113.5")
  |> request.set_header("x-forwarded-proto", "https")
  |> request.set_header("x-forwarded-host", "example.com:8443")
}

pub fn trusted_proxies_set_the_origin_test() {
  // server.handle acts as a connection from 127.0.0.1.
  server.new(routes(), Nil)
  |> server.trust_proxies(["127.0.0.1"])
  |> server.handle(forwarded_request())
  |> rendered_body
  |> should.equal("203.0.113.5 https://example.com:8443")
}

pub fn other_peers_cannot_forward_test() {
  server.new(routes(), Nil)
  |> server.trust_proxies(["10.0.0.0/8"])
  |> server.handle(forwarded_request())
  |> rendered_body
  |> should.equal("127.0.0.1 http://localhost")
}

pub fn real_connections_use_the_peer_address_test() {
  let assert Ok(srv) =
    server.new(routes(), Nil)
    |> server.port(0)
    |> server.trust_proxies(["127.0.0.1"])
    |> server.start
  let assert Ok(socket) = connect(server.port_of(srv))
  send(socket, "GET / HTTP/1.1\r\nhost: localhost:9\r\n\r\n")
  let assert Ok(#(200, _, body)) = read_response(socket, 1000)
  body |> should.equal(<<"127.0.0.1 http://localhost:9">>)
  send(
    socket,
    "GET / HTTP/1.1\r\nhost: internal\r\nx-forwarded-for: 198.51.100.4\r\nx-forwarded-proto: https\r\nx-forwarded-host: example.com\r\n\r\n",
  )
  let assert Ok(#(200, _, body)) = read_response(socket, 1000)
  body |> should.equal(<<"198.51.100.4 https://example.com">>)
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

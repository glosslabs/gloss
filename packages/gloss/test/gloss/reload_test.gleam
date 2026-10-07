import gleam/int
import gleam/string
import gleam/time/duration
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import gloss/reload

type Socket

fn directory() -> String {
  // Unique across runs too, so no file from an earlier run is there.
  let dir =
    "build/test-reload/"
    <> int.to_string(system_time())
    <> "-"
    <> int.to_string(unique_integer([Positive]))
  write(dir <> "/style.css", "a{}")
  dir
}

fn start(dir: String, command: List(String)) {
  let assert Ok(reloader) =
    reload.new()
    |> reload.watch(dir)
    |> reload.command(command)
    |> reload.interval(duration.milliseconds(50))
    |> reload.start
  let assert Ok(srv) =
    router.new()
    |> router.get("/", fn(_, _) {
      reply.html(200, "<html><body><p>hi</p></body></html>")
    })
    |> server.new(Nil)
    |> server.port(0)
    |> server.with(reload.middleware(reloader))
    |> server.start
  #(reloader, srv)
}

/// Open the event stream: the socket, and what has arrived so far, which
/// may already include an event.
fn listen(port: Int) -> #(Socket, String) {
  let assert Ok(socket) = connect(port)
  send(socket, "GET /_gloss/reload/events HTTP/1.1\r\nhost: localhost\r\n\r\n")
  let assert Ok(head) = recv_until(socket, "\r\n\r\n", 1000)
  assert string.contains(head, "text/event-stream")
  #(socket, head)
}

/// Wait for `event`, unless it already arrived in `seen`.
fn expect(socket: Socket, seen: String, event: String) -> Nil {
  case string.contains(seen, event) {
    True -> Nil
    False -> {
      let assert Ok(_) = recv_until(socket, event, 2000)
      Nil
    }
  }
}

pub fn pages_get_the_script_test() {
  let dir = directory()
  let #(_, srv) = start(dir, ["true"])
  let assert Ok(socket) = connect(server.port_of(srv))
  send(socket, "GET / HTTP/1.1\r\nhost: localhost\r\n\r\n")
  let assert Ok(page) = recv_until(socket, "</html>", 1000)
  assert string.contains(
    page,
    "<script src=\"/_gloss/reload/reload.js\" defer></script></body>",
  )
  let _ = server.shutdown(srv)
}

pub fn a_changed_asset_reloads_pages_test() {
  let dir = directory()
  let #(_, srv) = start(dir, ["false"])
  let #(socket, _) = listen(server.port_of(srv))
  // Asset changes don't build, so the failing command isn't run.
  write(dir <> "/style.css", "a{color:red}")
  let assert Ok(events) = recv_until(socket, "event: reload", 2000)
  assert !string.contains(events, "event: failed")
  let _ = server.shutdown(srv)
}

pub fn a_failed_build_is_shown_until_one_succeeds_test() {
  let dir = directory()
  let marker = dir <> "/ok"
  // Fails until the marker file exists.
  let #(_, srv) = start(dir, ["test", "-e", marker])
  let #(socket, _) = listen(server.port_of(srv))
  write(dir <> "/page.gleam", "pub fn x() { 1 }")
  let assert Ok(_) = recv_until(socket, "event: failed", 2000)

  // A page opened now is told about the failure at once.
  let #(late, seen) = listen(server.port_of(srv))
  expect(late, seen, "event: failed")

  write(marker, "")
  write(dir <> "/page.gleam", "pub fn x() { 2 }")
  let assert Ok(_) = recv_until(socket, "event: reload", 2000)
  let _ = server.shutdown(srv)
}

@external(erlang, "http_client_ffi", "connect")
fn connect(port: Int) -> Result(Socket, Nil)

@external(erlang, "http_client_ffi", "send")
fn send(socket: Socket, data: String) -> Nil

@external(erlang, "http_client_ffi", "recv_until")
fn recv_until(
  socket: Socket,
  needle: String,
  timeout: Int,
) -> Result(String, Nil)

@external(erlang, "static_test_ffi", "write")
fn write(path: String, contents: String) -> Nil

@external(erlang, "os", "system_time")
fn system_time() -> Int

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueOption)) -> Int

type UniqueOption {
  Positive
}

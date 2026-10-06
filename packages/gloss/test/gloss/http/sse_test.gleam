import gleam/http
import gleam/http/request
import gleam/list
import gleeunit/should
import gloss/http/router
import gloss/http/server
import gloss/http/sse
import http_support.{header, rendered_body, request}

pub fn encode_test() {
  sse.event("hello") |> sse.encode |> should.equal("data: hello\n\n")
  sse.event("line one\nline two\r\nthree")
  |> sse.name("note")
  |> sse.id("7")
  |> sse.retry(5000)
  |> sse.encode
  |> should.equal(
    "event: note\nid: 7\nretry: 5000\ndata: line one\ndata: line two\ndata: three\n\n",
  )
  sse.event("x")
  |> sse.name("a\nb")
  |> sse.encode
  |> should.equal("event: a b\ndata: x\n\n")
  sse.keep_alive() |> sse.encode |> should.equal(":\n\n")
}

pub fn stream_test() {
  let routes =
    router.new()
    |> router.get("/events", fn(_, _) {
      use send <- sse.stream
      ["a", "b"]
      |> list.each(fn(data) {
        let _ = send(sse.event(data))
        Nil
      })
    })
  let res = server.handle(server.new(routes, Nil), request(http.Get, "/events"))
  res.status |> should.equal(200)
  header(res, "content-type") |> should.equal("text/event-stream")
  header(res, "cache-control") |> should.equal("no-cache")
  rendered_body(res) |> should.equal("data: a\n\ndata: b\n\n")
}

pub fn last_event_id_test() {
  request(http.Get, "/")
  |> request.set_header("last-event-id", "42")
  |> sse.last_event_id
  |> should.equal(Ok("42"))
}

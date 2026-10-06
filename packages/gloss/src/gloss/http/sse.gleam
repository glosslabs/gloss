//// Server-sent events: a stream of messages a browser reads with
//// `EventSource`.
////
//// ```gleam
//// pub fn ticks(_req: Request, ctx: Context(State)) -> Response {
////   use send <- sse.stream
////   loop(fn(n) {
////     sse.event(int.to_string(n))
////     |> sse.name("tick")
////     |> send
////   })
//// }
//// ```
////
//// The producer runs until it returns. `send` returns `Error(Nil)` once the
//// client has gone or the server is shutting down: stop then. Browsers
//// reconnect on their own, sending the last event's `id` back in the
//// `last-event-id` header (see `last_event_id`).

import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gloss/http/reply.{type Request, type Response}

pub type Event {
  Event(
    data: String,
    name: Option(String),
    id: Option(String),
    retry: Option(Int),
  )
  /// A comment line, ignored by browsers.
  Comment(text: String)
}

/// Sends one event. `Error(Nil)` means stop.
pub type Send =
  fn(Event) -> Result(Nil, Nil)

/// An event with `data`, which may span several lines.
pub fn event(data: String) -> Event {
  Event(data:, name: None, id: None, retry: None)
}

/// The event's type, which `EventSource` dispatches on. Without one the
/// browser fires `message`.
pub fn name(event: Event, name: String) -> Event {
  case event {
    Event(..) -> Event(..event, name: Some(name))
    Comment(..) -> event
  }
}

/// The id the browser sends back as `last-event-id` when it reconnects.
pub fn id(event: Event, id: String) -> Event {
  case event {
    Event(..) -> Event(..event, id: Some(id))
    Comment(..) -> event
  }
}

/// How long the browser waits before reconnecting, in milliseconds.
pub fn retry(event: Event, milliseconds: Int) -> Event {
  case event {
    Event(..) -> Event(..event, retry: Some(milliseconds))
    Comment(..) -> event
  }
}

/// Answer `200` with `content-type: text/event-stream`, sending the events
/// the producer emits. Responses aren't cached, and proxies such as nginx
/// are asked not to buffer them.
pub fn stream(producer: fn(Send) -> Nil) -> Response {
  reply.stream(200, "text/event-stream", fn(emit) {
    producer(fn(event) { emit(bytes_tree.from_string(encode(event))) })
  })
  |> response.set_header("cache-control", "no-cache")
  |> response.set_header("x-accel-buffering", "no")
}

/// A comment line. Browsers ignore it; sending one now and then keeps idle
/// connections from being closed by proxies.
pub fn keep_alive() -> Event {
  Comment("")
}

/// The id of the last event the browser saw, when it is reconnecting.
pub fn last_event_id(req: Request) -> Result(String, Nil) {
  request.get_header(req, "last-event-id")
}

/// The event in the `text/event-stream` format, ending with a blank line.
pub fn encode(event: Event) -> String {
  case event {
    Comment(text) -> ":" <> one_line(text) <> "\n\n"
    Event(..) -> {
      let fields =
        list.flatten([
          field("event", event.name),
          field("id", event.id),
          field("retry", option.map(event.retry, int.to_string)),
          lines(event.data) |> list.map(fn(line) { "data: " <> line <> "\n" }),
        ])
      string.concat(fields) <> "\n"
    }
  }
}

fn field(name: String, value: Option(String)) -> List(String) {
  case value {
    Some(value) -> [name <> ": " <> one_line(value) <> "\n"]
    None -> []
  }
}

fn lines(text: String) -> List(String) {
  text
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
  |> string.split("\n")
}

/// Field values other than data can't span lines.
fn one_line(text: String) -> String {
  text |> lines |> string.join(" ")
}

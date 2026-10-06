//// One process per client connection: read a request, run the handler,
//// write the response, and repeat while the connection is kept alive.
////
//// The process listens for socket packets and drain requests together. A
//// drain request closes an idle connection at once; a connection in the
//// middle of a request finishes it, answers with `connection: close`, and
//// closes.

import gleam/bytes_tree.{type BytesTree}
import gleam/http
import gleam/http/response.{type Response}
import gleam/list
import gloss/http/reply.{type Request}
import gloss/internal/http_server_http1.{type Head, Head} as http1
import gloss/internal/http_server_tcp.{type Socket} as tcp

pub type Settings {
  Settings(
    /// Serve a request, returning the response ready to send.
    handler: fn(Request) -> Response(BytesTree),
    /// Render a response the connection itself produced, for a request
    /// with this `Accept` header.
    render: fn(reply.Response, Result(String, Nil)) -> Response(BytesTree),
    max_body: Int,
    /// Milliseconds allowed for each header line and the body once a
    /// request has started.
    header_timeout: Int,
    /// Milliseconds a kept-alive connection may wait for its next request.
    idle_timeout: Int,
    max_headers: Int,
    report: fn(Problem) -> Nil,
  )
}

/// A request rejected before it reached the handler.
pub type Problem {
  Malformed(detail: String)
  HeaderTimeout
  TooManyHeaders
  BodyTooLarge(length: Int)
  UnsupportedTransferEncoding
}

/// Serve the connection until it closes. Runs in the connection's process,
/// which must own the socket.
pub fn serve(socket: Socket, settings: Settings) -> Nil {
  await_request(socket, settings)
}

fn await_request(socket: Socket, settings: Settings) -> Nil {
  case tcp.next(socket, settings.idle_timeout) {
    tcp.RequestLine(method:, target:, version:) -> {
      let head =
        Head(method: http1.method(method), target:, version:, headers: [])
      read_headers(socket, settings, head, 0, False)
    }
    tcp.BadRequest(line:) ->
      reject(socket, settings, Error(Nil), 400, Malformed(line))
    tcp.Header(..) | tcp.EndOfHeaders ->
      reject(
        socket,
        settings,
        Error(Nil),
        400,
        Malformed("header before request line"),
      )
    tcp.Drain | tcp.Timeout | tcp.ConnectionClosed -> tcp.close(socket)
  }
}

fn read_headers(
  socket: Socket,
  settings: Settings,
  head: Head,
  count: Int,
  draining: Bool,
) -> Nil {
  case tcp.next(socket, settings.header_timeout) {
    tcp.Header(name:, value:) ->
      case count >= settings.max_headers {
        True -> reject(socket, settings, accept(head), 431, TooManyHeaders)
        False -> {
          let head = Head(..head, headers: [#(name, value), ..head.headers])
          read_headers(socket, settings, head, count + 1, draining)
        }
      }
    tcp.EndOfHeaders -> {
      let head = Head(..head, headers: list.reverse(head.headers))
      read_body(socket, settings, head, draining)
    }
    tcp.Drain -> read_headers(socket, settings, head, count, True)
    tcp.Timeout -> reject(socket, settings, accept(head), 408, HeaderTimeout)
    tcp.BadRequest(line:) ->
      reject(socket, settings, accept(head), 400, Malformed(line))
    tcp.RequestLine(..) ->
      reject(
        socket,
        settings,
        accept(head),
        400,
        Malformed("second request line"),
      )
    tcp.ConnectionClosed -> tcp.close(socket)
  }
}

fn read_body(
  socket: Socket,
  settings: Settings,
  head: Head,
  draining: Bool,
) -> Nil {
  case http1.content_length(head) {
    Error(http1.UnsupportedTransferEncoding) ->
      reject(socket, settings, accept(head), 501, UnsupportedTransferEncoding)
    Error(http1.InvalidContentLength) ->
      reject(
        socket,
        settings,
        accept(head),
        400,
        Malformed("invalid content-length"),
      )
    Ok(length) if length > settings.max_body ->
      reject(socket, settings, accept(head), 413, BodyTooLarge(length))
    Ok(length) -> {
      let continued = case length > 0 && http1.expects_continue(head) {
        True -> tcp.send(socket, bytes_tree.from_string(http1.continue))
        False -> Ok(Nil)
      }
      let body = case continued {
        Ok(Nil) -> tcp.read_body(socket, length, settings.header_timeout)
        Error(Nil) -> Error(Nil)
      }
      case body {
        Ok(body) -> respond(socket, settings, head, body, draining)
        Error(Nil) -> tcp.close(socket)
      }
    }
  }
}

fn respond(
  socket: Socket,
  settings: Settings,
  head: Head,
  body: BitArray,
  draining: Bool,
) -> Nil {
  let response = settings.handler(http1.to_request(head, body))
  // A drain requested while the handler ran is still waiting in the mailbox.
  let draining = draining || tcp.drain_requested()
  let keep_alive = !draining && http1.keep_alive(head)
  let wire =
    http1.encode(
      response,
      keep_alive:,
      head_request: head.method == http.Head,
      date: tcp.http_date(),
    )
  case tcp.send(socket, wire), keep_alive {
    Ok(Nil), True -> await_request(socket, settings)
    _, _ -> tcp.close(socket)
  }
}

/// Answer with an error and close the connection.
fn reject(
  socket: Socket,
  settings: Settings,
  accept: Result(String, Nil),
  status: Int,
  problem: Problem,
) -> Nil {
  settings.report(problem)
  let wire =
    http1.encode(
      settings.render(reply.error(status, message(problem)), accept),
      keep_alive: False,
      head_request: False,
      date: tcp.http_date(),
    )
  let _ = tcp.send(socket, wire)
  tcp.close(socket)
}

pub fn message(problem: Problem) -> String {
  case problem {
    Malformed(_) -> "malformed request"
    HeaderTimeout -> "request timeout"
    TooManyHeaders -> "too many headers"
    BodyTooLarge(_) -> "content too large"
    UnsupportedTransferEncoding -> "transfer-encoding is not supported"
  }
}

fn accept(head: Head) -> Result(String, Nil) {
  list.key_find(head.headers, "accept")
}

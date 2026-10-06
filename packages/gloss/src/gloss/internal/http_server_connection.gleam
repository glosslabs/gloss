//// One process per client connection: read a request, run the handler,
//// write the response, and repeat while the connection is kept alive.
////
//// The process listens for socket packets and drain requests together. A
//// drain request closes an idle connection at once; a connection in the
//// middle of a request finishes it, answers with `connection: close`, and
//// closes.

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/http
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/result
import gloss/http/reply.{type Request}
import gloss/internal/http_reply_render.{
  type Wire, SendFile, Sized, Stream, Upgraded,
}
import gloss/internal/http_request_body.{
  type BodyError, type RequestBody, RequestBody,
} as request_body
import gloss/internal/http_server_http1.{type Head, Head} as http1
import gloss/internal/http_server_tcp.{type Socket} as tcp

pub type Settings {
  Settings(
    /// Serve a request, returning the response ready to send.
    handler: fn(Request) -> Response(Wire),
    /// Render a response the connection itself produced, for a request
    /// with this `Accept` header.
    render: fn(reply.Response, Result(String, Nil)) -> Response(Wire),
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
  let reject = fn(status, problem) {
    reject(socket, settings, accept(head), status, problem)
  }
  case http1.body_framing(head) {
    Error(http1.UnsupportedTransferEncoding) ->
      reject(501, UnsupportedTransferEncoding)
    Error(http1.InvalidContentLength) ->
      reject(400, Malformed("invalid content-length"))
    Error(http1.ConflictingFraming) ->
      reject(400, Malformed("both transfer-encoding and content-length"))
    Ok(framing) -> {
      request_body.reset()
      let body = network_body(socket, settings, head, framing)
      respond(socket, settings, head, body, framing, draining)
    }
  }
}

/// The request's body, read from the socket when the handler asks.
fn network_body(
  socket: Socket,
  settings: Settings,
  head: Head,
  framing: http1.BodyFraming,
) -> RequestBody {
  // Tell a client waiting on `expect: 100-continue` to send the body, the
  // first time the handler reads it.
  let start = fn() {
    case http1.expects_continue(head), framing {
      True, http1.Chunked -> continue(socket)
      True, http1.Length(length) if length > 0 -> continue(socket)
      _, _ -> Nil
    }
  }
  RequestBody(
    read: fn() {
      case request_body.status(), framing {
        request_body.Buffered(bits), _ -> Ok(bits)
        request_body.Streamed, _ | request_body.Broken, _ ->
          Error(request_body.Consumed)
        request_body.Unread, http1.Length(length)
          if length > settings.max_body
        -> {
          request_body.set_status(request_body.Broken)
          Error(request_body.TooLarge(settings.max_body))
        }
        request_body.Unread, _ -> {
          start()
          let read =
            fold(socket, settings, framing, #([], 0), fn(acc, chunk) {
              let size = acc.1 + bit_array.byte_size(chunk)
              case size > settings.max_body {
                True -> Error(request_body.TooLarge(settings.max_body))
                False -> Ok(#([chunk, ..acc.0], size))
              }
            })
          case read {
            Ok(#(chunks, _)) -> {
              let bits = bit_array.concat(list.reverse(chunks))
              request_body.set_status(request_body.Buffered(bits))
              Ok(bits)
            }
            Error(error) -> {
              request_body.set_status(request_body.Broken)
              Error(error)
            }
          }
        }
      }
    },
    stream: fn(consume) {
      case request_body.status() {
        request_body.Buffered(bits) ->
          request_body.from_bits(bits).stream(consume)
        request_body.Streamed | request_body.Broken ->
          Error(request_body.Consumed)
        request_body.Unread -> {
          start()
          let streamed =
            fold(socket, settings, framing, 0, fn(total, chunk) {
              case consume(chunk) {
                True -> Ok(total + bit_array.byte_size(chunk))
                False -> Error(request_body.Stopped)
              }
            })
          request_body.set_status(case streamed {
            Ok(_) -> request_body.Streamed
            Error(_) -> request_body.Broken
          })
          streamed
        }
      }
    },
  )
}

fn continue(socket: Socket) -> Nil {
  let _ = tcp.send(socket, bytes_tree.from_string(http1.continue))
  Nil
}

/// The largest piece read from the socket at once.
const piece = 65_536

/// Read the body piece by piece, folding each piece into `acc`.
fn fold(
  socket: Socket,
  settings: Settings,
  framing: http1.BodyFraming,
  acc: acc,
  f: fn(acc, BitArray) -> Result(acc, BodyError),
) -> Result(acc, BodyError) {
  case framing {
    http1.Length(length) -> read_exact(socket, settings, length, acc, f)
    http1.Chunked -> read_chunks(socket, settings, acc, f)
  }
}

/// Read exactly `remaining` bytes.
fn read_exact(
  socket: Socket,
  settings: Settings,
  remaining: Int,
  acc: acc,
  f: fn(acc, BitArray) -> Result(acc, BodyError),
) -> Result(acc, BodyError) {
  case remaining {
    0 -> Ok(acc)
    _ -> {
      let size = int.min(remaining, piece)
      case tcp.read_body(socket, size, settings.header_timeout) {
        Error(Nil) -> Error(request_body.Incomplete)
        Ok(data) -> {
          use acc <- result.try(f(acc, data))
          read_exact(socket, settings, remaining - size, acc, f)
        }
      }
    }
  }
}

/// Read a chunked body: chunk-size lines, chunk data, then trailers, which
/// are ignored.
fn read_chunks(
  socket: Socket,
  settings: Settings,
  acc: acc,
  f: fn(acc, BitArray) -> Result(acc, BodyError),
) -> Result(acc, BodyError) {
  let timeout = settings.header_timeout
  use line <- result.try(
    tcp.read_line(socket, timeout)
    |> result.replace_error(request_body.Incomplete),
  )
  case http1.chunk_size(line) {
    Error(Nil) -> Error(request_body.Malformed("invalid chunk size"))
    Ok(0) -> {
      use Nil <- result.map(skip_trailers(socket, timeout))
      acc
    }
    Ok(size) -> {
      use acc <- result.try(read_exact(socket, settings, size, acc, f))
      case tcp.read_line(socket, timeout) {
        Ok("") -> read_chunks(socket, settings, acc, f)
        Ok(_) -> Error(request_body.Malformed("chunk data too long"))
        Error(Nil) -> Error(request_body.Incomplete)
      }
    }
  }
}

fn skip_trailers(socket: Socket, timeout: Int) -> Result(Nil, BodyError) {
  case tcp.read_line(socket, timeout) {
    Ok("") -> Ok(Nil)
    Ok(_) -> skip_trailers(socket, timeout)
    Error(Nil) -> Error(request_body.Incomplete)
  }
}

fn respond(
  socket: Socket,
  settings: Settings,
  head: Head,
  body: RequestBody,
  framing: http1.BodyFraming,
  draining: Bool,
) -> Nil {
  let response = settings.handler(http1.to_request(head, body))
  // A drain requested while the handler ran is still waiting in the mailbox.
  let draining = draining || tcp.drain_requested()
  // Unread or half-read body bytes would be taken for the next request.
  let consumed = case request_body.status(), framing {
    request_body.Buffered(_), _ | request_body.Streamed, _ -> True
    request_body.Unread, http1.Length(0) -> True
    _, _ -> False
  }
  let keep_alive = !draining && consumed && http1.keep_alive(head)
  let written =
    write(socket, response, keep_alive, head.method == http.Head, head.version)
  case written, keep_alive {
    Ok(Nil), True -> await_request(socket, settings)
    _, _ -> tcp.close(socket)
  }
}

fn write(
  socket: Socket,
  response: Response(Wire),
  keep_alive: Bool,
  head_request: Bool,
  version: #(Int, Int),
) -> Result(Nil, Nil) {
  let date = tcp.http_date()
  case response.body {
    Sized(tree) ->
      tcp.send(
        socket,
        http1.encode(
          response.set_body(response, tree),
          keep_alive:,
          head_request:,
          date:,
        ),
      )
    SendFile(path:, offset:, length:) -> {
      let framing = http1.ContentLength(length)
      let head = http1.head(response, framing:, keep_alive:, date:)
      case tcp.send(socket, head), head_request {
        Ok(Nil), False -> tcp.sendfile(socket, path, offset, length)
        result, _ -> result
      }
    }
    Upgraded(run) -> {
      let head =
        http1.head(response, framing: http1.Switching, keep_alive:, date:)
      case tcp.send(socket, head) {
        Ok(Nil) -> run(socket)
        Error(Nil) -> Nil
      }
      // The socket is done once the upgraded protocol returns.
      Error(Nil)
    }
    Stream(producer) -> {
      // HTTP/1.0 has no chunked encoding: send the body bare and close.
      let #(framing, keep_alive) = case version {
        #(1, 1) -> #(http1.ChunkedResponse, keep_alive)
        _ -> #(http1.UntilClose, False)
      }
      let head = http1.head(response, framing:, keep_alive:, date:)
      case tcp.send(socket, head), head_request {
        Ok(Nil), False -> stream(socket, producer, framing)
        result, _ -> result
      }
    }
  }
}

/// Run a stream's producer, sending what it emits. `emit` fails once the
/// client is gone or the server is draining, so the producer can stop.
fn stream(
  socket: Socket,
  producer: fn(fn(BytesTree) -> Result(Nil, Nil)) -> Nil,
  framing: http1.ResponseFraming,
) -> Result(Nil, Nil) {
  let emit = fn(data: BytesTree) {
    case tcp.drain_requested(), bytes_tree.byte_size(data) {
      True, _ -> Error(Nil)
      False, 0 -> Ok(Nil)
      False, _ ->
        case framing {
          http1.ChunkedResponse -> tcp.send(socket, http1.chunk(data))
          _ -> tcp.send(socket, data)
        }
    }
  }
  producer(emit)
  case framing, tcp.drain_requested() {
    // Draining: finish the body properly, then close.
    http1.ChunkedResponse, draining -> {
      let ended = tcp.send(socket, bytes_tree.from_string(http1.last_chunk))
      case draining {
        True -> Error(Nil)
        False -> ended
      }
    }
    _, _ -> Error(Nil)
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
  let response = settings.render(reply.error(status, message(problem)), accept)
  let _ = write(socket, response, False, False, #(1, 1))
  tcp.close(socket)
}

pub fn message(problem: Problem) -> String {
  case problem {
    Malformed(_) -> "malformed request"
    HeaderTimeout -> "request timeout"
    TooManyHeaders -> "too many headers"
    UnsupportedTransferEncoding -> "transfer-encoding is not supported"
  }
}

fn accept(head: Head) -> Result(String, Nil) {
  list.key_find(head.headers, "accept")
}

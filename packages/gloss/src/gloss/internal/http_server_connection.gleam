//// One process per client connection: read a request, run the handler,
//// write the response, and repeat while the connection is kept alive.
////
//// The process listens for socket packets and drain requests together. A
//// drain request closes an idle connection at once; a connection in the
//// middle of a request finishes it, answers with `connection: close`, and
//// closes.

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process
import gleam/http
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloss/http/reply.{type Request}
import gloss/internal/http_reply_render.{
  type Wire, SendFile, SendSegments, Sized, Stream, Upgraded,
}
import gloss/internal/http_request_body.{
  type BodyError, type RequestBody, RequestBody,
} as request_body
import gloss/internal/http_server_http1.{type Head, Head} as http1
import gloss/internal/http_server_tcp.{type Socket} as tcp

pub type Settings {
  Settings(
    /// Serve a request, returning the response ready to send.
    /// Serve a request from the peer at this address.
    handler: fn(Request, String) -> Response(Wire),
    /// The connection's remote address; set by `serve`.
    peer: String,
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
    /// Milliseconds a handler may run without the request body making
    /// progress; `None` for no limit.
    request_timeout: Option(Int),
    report: fn(Problem) -> Nil,
  )
}

/// A request rejected before it reached the handler.
pub type Problem {
  Malformed(detail: String)
  HeaderTimeout
  TooManyHeaders
  /// The request line is longer than the server reads.
  UriTooLong
  /// A header line is longer than the server reads.
  HeaderTooLarge
  /// An `Expect` header the server can't meet.
  UnknownExpectation(value: String)
  UnsupportedTransferEncoding
  /// The handler ran past the request timeout and was stopped.
  RequestTimeout
  /// The handler's process died outside the server's panic handling.
  HandlerCrashed(reason: String)
}

/// Serve the connection until it closes. Runs in the connection's process,
/// which must own the socket.
pub fn serve(socket: Socket, settings: Settings) -> Nil {
  await_request(socket, Settings(..settings, peer: tcp.peer_address(socket)))
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
    tcp.LineTooLong -> reject(socket, settings, Error(Nil), 414, UriTooLong)
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
    tcp.LineTooLong ->
      reject(socket, settings, accept(head), 431, HeaderTooLarge)
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
  case http1.check(head), http1.body_framing(head) {
    Error(http1.MissingHost), _ -> reject(400, Malformed("missing host header"))
    Error(http1.MultipleHosts), _ ->
      reject(400, Malformed("more than one host header"))
    Error(http1.UnknownExpectation(value)), _ ->
      reject(417, UnknownExpectation(value))
    Ok(Nil), Error(http1.UnsupportedTransferEncoding) ->
      reject(501, UnsupportedTransferEncoding)
    Ok(Nil), Error(http1.InvalidContentLength) ->
      reject(400, Malformed("invalid content-length"))
    Ok(Nil), Error(http1.ConflictingFraming) ->
      reject(400, Malformed("both transfer-encoding and content-length"))
    Ok(Nil), Ok(framing) -> {
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
  let compressed = encoding(head) != Identity
  RequestBody(
    read: fn() {
      case request_body.status(), framing {
        request_body.Buffered(bits), _ -> Ok(bits)
        request_body.Streamed, _ | request_body.Broken, _ ->
          Error(request_body.Consumed)
        request_body.Unread, http1.Length(length)
          if length > settings.max_body && !compressed
        -> {
          request_body.set_status(request_body.Broken)
          Error(request_body.TooLarge(settings.max_body))
        }
        request_body.Unread, _ -> {
          start()
          let read =
            fold_decoded(
              socket,
              settings,
              head,
              framing,
              #([], 0),
              fn(acc, chunk) {
                let size = acc.1 + bit_array.byte_size(chunk)
                case size > settings.max_body {
                  True -> Error(request_body.TooLarge(settings.max_body))
                  False -> Ok(#([chunk, ..acc.0], size))
                }
              },
            )
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
            fold_decoded(socket, settings, head, framing, 0, fn(total, chunk) {
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
    limit: settings.max_body,
  )
}

fn continue(socket: Socket) -> Nil {
  let _ = tcp.send(socket, bytes_tree.from_string(http1.continue))
  Nil
}

type Encoding {
  Identity
  Gzip
  Unsupported(String)
}

fn encoding(head: Head) -> Encoding {
  let codings =
    head.headers
    |> list.filter(fn(header) { header.0 == "content-encoding" })
    |> list.flat_map(fn(header) { string.split(header.1, ",") })
    |> list.map(fn(coding) { string.lowercase(string.trim(coding)) })
    |> list.filter(fn(coding) { coding != "" && coding != "identity" })
  case codings {
    [] -> Identity
    ["gzip"] | ["x-gzip"] -> Gzip
    _ -> Unsupported(string.join(codings, ", "))
  }
}

/// Read the body, inflating it first when it is gzipped.
fn fold_decoded(
  socket: Socket,
  settings: Settings,
  head: Head,
  framing: http1.BodyFraming,
  acc: acc,
  f: fn(acc, BitArray) -> Result(acc, BodyError),
) -> Result(acc, BodyError) {
  case encoding(head), framing {
    Identity, _ | Gzip, http1.Length(0) ->
      fold(socket, settings, framing, acc, f)
    Unsupported(coding), _ -> Error(request_body.UnsupportedEncoding(coding))
    Gzip, _ -> {
      let z = inflate_open()
      let read =
        fold(socket, settings, framing, acc, fn(acc, piece) {
          inflated(z, inflate(z, piece), acc, f)
        })
      case read, inflate_end(z) {
        Ok(acc), Ok(Nil) -> Ok(acc)
        Ok(_), Error(Nil) ->
          Error(request_body.Malformed("truncated gzip body"))
        Error(error), _ -> Error(error)
      }
    }
  }
}

/// Fold each piece of inflated output, a bounded amount at a time.
fn inflated(
  z: Inflater,
  step: Inflated,
  acc: acc,
  f: fn(acc, BitArray) -> Result(acc, BodyError),
) -> Result(acc, BodyError) {
  case step {
    InflateFailed -> Error(request_body.Malformed("invalid gzip body"))
    Done(out) -> fold_piece(acc, out, f)
    More(out) -> {
      use acc <- result.try(fold_piece(acc, out, f))
      inflated(z, inflate_continue(z), acc, f)
    }
  }
}

fn fold_piece(
  acc: acc,
  piece: BitArray,
  f: fn(acc, BitArray) -> Result(acc, BodyError),
) -> Result(acc, BodyError) {
  case bit_array.byte_size(piece) {
    0 -> Ok(acc)
    _ -> f(acc, piece)
  }
}

type Inflater

type Inflated {
  More(BitArray)
  Done(BitArray)
  InflateFailed
}

@external(erlang, "gloss@http@server_ffi", "inflate_open")
fn inflate_open() -> Inflater

@external(erlang, "gloss@http@server_ffi", "inflate")
fn inflate(z: Inflater, data: BitArray) -> Inflated

@external(erlang, "gloss@http@server_ffi", "inflate_continue")
fn inflate_continue(z: Inflater) -> Inflated

@external(erlang, "gloss@http@server_ffi", "inflate_end")
fn inflate_end(z: Inflater) -> Result(Nil, Nil)

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
          request_body.progress()
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
  case run_handler(settings, http1.to_request(head, body)) {
    Ok(#(response, status)) ->
      send_response(socket, settings, head, framing, draining, response, status)
    Error(problem) -> {
      let status = case problem {
        RequestTimeout -> 503
        _ -> 500
      }
      reject(socket, settings, accept(head), status, problem)
    }
  }
}

/// Run the handler in its own process, so it can be stopped at the request
/// timeout. Each piece of request body it reads restarts the clock.
fn run_handler(
  settings: Settings,
  request: Request,
) -> Result(#(Response(Wire), request_body.Status), Problem) {
  let done = process.new_subject()
  let progress = process.new_subject()
  let handler = settings.handler
  let peer = settings.peer
  let pid =
    process.spawn_unlinked(fn() {
      request_body.watch(progress)
      let response = handler(request, peer)
      process.send(done, #(response, request_body.status()))
    })
  // A handler that has already exited still produces a `DOWN` message.
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_map(done, Finished)
    |> process.select_map(progress, fn(_) { Progress })
    |> process.select_specific_monitor(monitor, fn(down) {
      case down {
        process.ProcessDown(reason:, ..) -> Crashed(string.inspect(reason))
        process.PortDown(..) -> Crashed("port down")
      }
    })
    |> process.select_other(fn(message) {
      // Drain requests are remembered for after the response.
      case tcp.is_drain(message) {
        True -> Progress
        False -> Ignored
      }
    })
  let result = await_handler(selector, settings.request_timeout)
  case result {
    Error(RequestTimeout) -> process.kill(pid)
    _ -> Nil
  }
  process.demonitor_process(monitor)
  result
}

type HandlerEvent {
  Finished(#(Response(Wire), request_body.Status))
  Progress
  Crashed(String)
  Ignored
}

fn await_handler(
  selector: process.Selector(HandlerEvent),
  timeout: Option(Int),
) -> Result(#(Response(Wire), request_body.Status), Problem) {
  let event = case timeout {
    Some(ms) -> process.selector_receive(selector, ms)
    None -> Ok(process.selector_receive_forever(selector))
  }
  case event {
    Ok(Finished(result)) -> Ok(result)
    Ok(Crashed(reason)) -> Error(HandlerCrashed(reason))
    Ok(Progress) | Ok(Ignored) -> await_handler(selector, timeout)
    Error(Nil) -> Error(RequestTimeout)
  }
}

fn send_response(
  socket: Socket,
  settings: Settings,
  head: Head,
  framing: http1.BodyFraming,
  draining: Bool,
  response: Response(Wire),
  status: request_body.Status,
) -> Nil {
  // A drain requested while the handler ran is remembered.
  let draining = draining || tcp.drain_requested()
  // Unread or half-read body bytes would be taken for the next request.
  let consumed = case status, framing {
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
    SendSegments(segments) -> {
      let length = case http_reply_render.length(response.body) {
        Ok(length) -> length
        Error(Nil) -> 0
      }
      let framing = http1.ContentLength(length)
      let head = http1.head(response, framing:, keep_alive:, date:)
      case tcp.send(socket, head), head_request {
        Ok(Nil), False -> send_segments(socket, segments)
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

fn send_segments(
  socket: Socket,
  segments: List(reply.Segment),
) -> Result(Nil, Nil) {
  case segments {
    [] -> Ok(Nil)
    [segment, ..rest] -> {
      let sent = case segment {
        reply.Data(tree) -> tcp.send(socket, tree)
        reply.FileRange(path:, offset:, length:) ->
          tcp.sendfile(socket, path, offset, length)
      }
      case sent {
        Ok(Nil) -> send_segments(socket, rest)
        Error(Nil) -> Error(Nil)
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
    UriTooLong -> "uri too long"
    HeaderTooLarge -> "header too large"
    UnknownExpectation(_) -> "expectation not supported"
    UnsupportedTransferEncoding -> "transfer-encoding is not supported"
    RequestTimeout -> "request timed out"
    HandlerCrashed(_) -> "internal server error"
  }
}

fn accept(head: Head) -> Result(String, Nil) {
  list.key_find(head.headers, "accept")
}

//// W3C Trace Context: the `traceparent` header that carries a trace from
//// one service to the next.
////
//// The server continues the trace an incoming `traceparent` names, or
//// starts a new one, and gives each request its own span id. Pass the
//// request's trace on to the services it calls, so their spans join it:
////
//// ```gleam
//// request.new()
//// |> request.set_header("traceparent", traceparent.header(ctx.trace))
//// ```
////
//// The ids also appear in the request span's meta as `trace_id`,
//// `span_id` and, when the trace came from upstream, `parent_span_id`.

import gleam/bit_array
import gleam/http/request
import gleam/list
import gleam/string
import gloss/http/reply.{type Request}

pub type TraceParent {
  TraceParent(
    /// 32 lowercase hex characters, shared by every span in the trace.
    trace_id: String,
    /// 16 lowercase hex characters: the span of the work at hand.
    span_id: String,
    /// Whether the trace's owner asked for it to be recorded.
    sampled: Bool,
  )
}

/// A new trace, sampled.
pub fn new() -> TraceParent {
  TraceParent(trace_id: random_hex(16), span_id: random_hex(8), sampled: True)
}

/// A new span in the same trace, e.g. for each request in a trace that
/// arrived from upstream.
pub fn child(parent: TraceParent) -> TraceParent {
  TraceParent(..parent, span_id: random_hex(8))
}

/// The trace named by the request's `traceparent` header.
pub fn from_request(req: Request) -> Result(TraceParent, Nil) {
  case request.get_header(req, "traceparent") {
    Ok(header) -> parse(header)
    Error(Nil) -> Error(Nil)
  }
}

/// Parse a `traceparent` value. Versions after `00` are accepted as long as
/// their first four fields have the same shape, as the spec asks.
pub fn parse(header: String) -> Result(TraceParent, Nil) {
  case string.split(string.trim(header), "-") {
    [version, trace_id, span_id, flags, ..rest] -> {
      let valid =
        hex(version, 2)
        && version != "ff"
        && { version != "00" || rest == [] }
        && hex(trace_id, 32)
        && trace_id != string.repeat("0", 32)
        && hex(span_id, 16)
        && span_id != string.repeat("0", 16)
        && hex(flags, 2)
      case valid {
        True ->
          Ok(TraceParent(trace_id:, span_id:, sampled: sampled_flag(flags)))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// The `traceparent` value for calls made within `trace`.
pub fn header(trace: TraceParent) -> String {
  let flags = case trace.sampled {
    True -> "01"
    False -> "00"
  }
  "00-" <> trace.trace_id <> "-" <> trace.span_id <> "-" <> flags
}

fn hex(text: String, length: Int) -> Bool {
  string.length(text) == length
  && string.to_graphemes(text)
  |> list.all(fn(c) { string.contains("0123456789abcdef", c) })
}

fn sampled_flag(flags: String) -> Bool {
  // The low bit of the flags byte.
  case string.last(flags) {
    Ok(c) -> string.contains("13579bdf", c)
    Error(Nil) -> False
  }
}

fn random_hex(bytes: Int) -> String {
  strong_rand_bytes(bytes) |> bit_array.base16_encode |> string.lowercase
}

@external(erlang, "crypto", "strong_rand_bytes")
fn strong_rand_bytes(n: Int) -> BitArray

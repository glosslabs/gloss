//// AWS Signature Version 4 for S3: signing requests in an `authorization`
//// header, and presigning URLs with the signature in the query string.
//// See https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html

import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import gloss/url

pub type Credentials {
  Credentials(
    access_key_id: String,
    secret_access_key: String,
    session_token: Option(String),
    region: String,
  )
}

/// The `x-amz-content-sha256` of a presigned request, whose body isn't
/// known when the URL is made.
pub const unsigned_payload = "UNSIGNED-PAYLOAD"

/// Sign `req`, adding `x-amz-date`, `x-amz-content-sha256`, any session
/// token and `authorization`. Every header on the request is signed, as is
/// `host`, which is computed from the request rather than set on it.
/// The request's path and query must already be URI-encoded.
pub fn sign(
  req: Request(BitArray),
  credentials: Credentials,
  at: Timestamp,
  payload_hash: String,
) -> Request(BitArray) {
  let #(date, amz_date) = dates(at)
  let req =
    req
    |> request.set_header("x-amz-date", amz_date)
    |> request.set_header("x-amz-content-sha256", payload_hash)
  let req = case credentials.session_token {
    Some(token) -> request.set_header(req, "x-amz-security-token", token)
    None -> req
  }
  let headers = signed_headers(req)
  let canonical =
    canonical_request(
      req.method,
      req.path,
      parse_query(req.query),
      headers,
      payload_hash,
    )
  let scope = scope(date, credentials.region)
  let signature = signature(credentials, date, amz_date, scope, canonical)
  request.set_header(
    req,
    "authorization",
    "AWS4-HMAC-SHA256 Credential="
      <> credentials.access_key_id
      <> "/"
      <> scope
      <> ", SignedHeaders="
      <> header_names(headers)
      <> ", Signature="
      <> signature,
  )
}

/// A URL for `req` that is valid for `expires` seconds from `at`, signed
/// over the host only, with an unsigned payload.
pub fn presign(
  req: Request(BitArray),
  credentials: Credentials,
  at: Timestamp,
  expires: Int,
) -> String {
  let #(date, amz_date) = dates(at)
  let scope = scope(date, credentials.region)
  let params =
    list.flatten([
      parse_query(req.query),
      [
        #("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
        #("X-Amz-Credential", credentials.access_key_id <> "/" <> scope),
        #("X-Amz-Date", amz_date),
        #("X-Amz-Expires", int.to_string(expires)),
      ],
      case credentials.session_token {
        Some(token) -> [#("X-Amz-Security-Token", token)]
        None -> []
      },
      [#("X-Amz-SignedHeaders", "host")],
    ])
  let canonical =
    canonical_request(
      req.method,
      req.path,
      params,
      [#("host", host(req))],
      unsigned_payload,
    )
  let signature = signature(credentials, date, amz_date, scope, canonical)
  let query = canonical_query(params) <> "&X-Amz-Signature=" <> signature
  http.scheme_to_string(req.scheme)
  <> "://"
  <> host(req)
  <> req.path
  <> "?"
  <> query
}

/// The canonical request: method, path, query, headers, signed header
/// names and payload hash, one per line.
pub fn canonical_request(
  method: http.Method,
  path: String,
  query: List(#(String, String)),
  headers: List(#(String, String)),
  payload_hash: String,
) -> String {
  [
    http.method_to_string(method) |> string.uppercase,
    path,
    canonical_query(query),
    list.map(headers, fn(h) { h.0 <> ":" <> h.1 <> "\n" }) |> string.concat,
    header_names(headers),
    payload_hash,
  ]
  |> string.join("\n")
}

fn signature(
  credentials: Credentials,
  date: String,
  amz_date: String,
  scope: String,
  canonical: String,
) -> String {
  let to_sign =
    ["AWS4-HMAC-SHA256", amz_date, scope, sha256_hex(<<canonical:utf8>>)]
    |> string.join("\n")
  let key =
    <<"AWS4":utf8, credentials.secret_access_key:utf8>>
    |> hmac(date)
    |> hmac(credentials.region)
    |> hmac("s3")
    |> hmac("aws4_request")
  crypto.hmac(<<to_sign:utf8>>, crypto.Sha256, key) |> hex
}

fn hmac(key: BitArray, data: String) -> BitArray {
  crypto.hmac(<<data:utf8>>, crypto.Sha256, key)
}

fn scope(date: String, region: String) -> String {
  date <> "/" <> region <> "/s3/aws4_request"
}

/// The request's headers and `host`, lower-cased, trimmed and sorted.
fn signed_headers(req: Request(BitArray)) -> List(#(String, String)) {
  [#("host", host(req)), ..req.headers]
  |> list.map(fn(h) { #(string.lowercase(h.0), collapse(string.trim(h.1))) })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

fn header_names(headers: List(#(String, String))) -> String {
  list.map(headers, fn(h) { h.0 }) |> string.join(";")
}

/// Runs of spaces inside a header value become one.
fn collapse(value: String) -> String {
  case string.contains(value, "  ") {
    True -> collapse(string.replace(value, "  ", " "))
    False -> value
  }
}

/// The host as signed and sent: with the port when it isn't the scheme's
/// default.
pub fn host(req: Request(a)) -> String {
  case req.port, req.scheme {
    None, _ | Some(80), http.Http | Some(443), http.Https -> req.host
    Some(port), _ -> req.host <> ":" <> int.to_string(port)
  }
}

/// Encoded `key=value` pairs, sorted by key then value, joined with `&`.
/// The pairs are given unencoded.
pub fn canonical_query(params: List(#(String, String))) -> String {
  params
  |> list.map(fn(p) { #(encode(p.0), encode(p.1)) })
  |> list.sort(fn(a, b) {
    case string.compare(a.0, b.0) {
      order.Eq -> string.compare(a.1, b.1)
      other -> other
    }
  })
  |> list.map(fn(p) { p.0 <> "=" <> p.1 })
  |> string.join("&")
}

/// A query string as sent: like `canonical_query`, but a parameter with no
/// value is written bare (`?uploads`).
pub fn query_string(params: List(#(String, String))) -> String {
  params
  |> list.map(fn(p) {
    case p.1 {
      "" -> encode(p.0)
      value -> encode(p.0) <> "=" <> encode(value)
    }
  })
  |> list.sort(string.compare)
  |> string.join("&")
}

/// A request's query string as unencoded pairs; `uploads` is `uploads=`.
pub fn parse_query(query: Option(String)) -> List(#(String, String)) {
  case query {
    None | Some("") -> []
    Some(query) ->
      string.split(query, "&")
      |> list.map(fn(pair) {
        case string.split_once(pair, "=") {
          Ok(#(key, value)) -> #(decode(key), decode(value))
          Error(Nil) -> #(decode(pair), "")
        }
      })
  }
}

/// URI-encode everything but the unreserved characters `A-Z a-z 0-9 - _ . ~`.
pub fn encode(text: String) -> String {
  url.encode(text)
}

/// Encode each segment of a key, keeping its `/`s.
pub fn encode_path(text: String) -> String {
  string.split(text, "/") |> list.map(encode) |> string.join("/")
}

fn decode(text: String) -> String {
  url.decode(text) |> result.unwrap(text)
}

/// `YYYYMMDD` and `YYYYMMDDTHHMMSSZ` in UTC.
fn dates(at: Timestamp) -> #(String, String) {
  let #(day, time) = timestamp.to_calendar(at, calendar.utc_offset)
  let date =
    pad(day.year, 4)
    <> pad(calendar.month_to_int(day.month), 2)
    <> pad(day.day, 2)
  #(
    date,
    date
      <> "T"
      <> pad(time.hours, 2)
      <> pad(time.minutes, 2)
      <> pad(time.seconds, 2)
      <> "Z",
  )
}

fn pad(n: Int, width: Int) -> String {
  string.pad_start(int.to_string(n), width, "0")
}

pub fn sha256_hex(data: BitArray) -> String {
  crypto.hash(crypto.Sha256, data) |> hex
}

fn hex(bytes: BitArray) -> String {
  bit_array.base16_encode(bytes) |> string.lowercase
}

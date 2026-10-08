//// An S3 client: objects, listing, copying, presigned URLs and multipart
//// uploads, for AWS S3 and anything that speaks its API (MinIO, Cloudflare
//// R2, Backblaze B2, DigitalOcean Spaces, ...).
////
//// ```gleam
//// import gleam/httpc
//// import gloss/s3
////
//// let uploads =
////   s3.new(access_key_id:, secret_access_key:, region: "eu-west-2", send: httpc.send_bits)
////   |> s3.tracer(tracer)
////   |> s3.bucket("forum-uploads")
////
//// let assert Ok(_etag) =
////   s3.put_object(uploads, "avatars/7.png", png, s3.PutOptions(
////     ..s3.put_options(),
////     content_type: Some("image/png"),
////   ))
//// let assert Ok(object) = s3.get_object(uploads, "avatars/7.png", range: None)
//// let url = s3.presign_get(uploads, "avatars/7.png", expires: duration.minutes(10))
//// ```
////
//// ## Sending
////
//// Requests go through the function given to `new`, typically
//// `httpc.send_bits`, so this package has no HTTP client of its own and
//// tests can answer requests themselves. Each request is signed with AWS
//// Signature Version 4, including the SHA-256 of its body; presigned URLs
//// leave the body unsigned, as it isn't known when they are made.
////
//// ## Buckets
////
//// Operations act on a `Bucket`, made from a client with `bucket`. Most
//// applications use one or two buckets, so binding the name once keeps
//// every call short, and the bucket decides how requests are addressed.
////
//// Without an `endpoint`, requests go to AWS at
//// `https://<bucket>.s3.<region>.amazonaws.com` (virtual-hosted style).
//// With one, such as MinIO's `http://localhost:9000`, they go to
//// `<endpoint>/<bucket>/<key>` (path style), which works for any bucket
//// name and needs no DNS; `path_style` overrides either default.
////
//// ## Tracing
////
//// Each request is a span from source `gloss.s3` named after the
//// operation (`put_object`, `list_objects`, ...), with `bucket`, `key`,
//// `bytes` and `status` in its meta, failed when the request fails. It is
//// a child of the calling process's current span, so S3 calls made while
//// handling a request appear in that request's trace.

import gleam/bit_array
import gleam/crypto
import gleam/float
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import gleam/uri
import gloss/clock.{type Clock}
import gloss/meta.{type Meta}
import gloss/s3/internal/sigv4
import gloss/s3/internal/xml
import gloss/tracer.{type Tracer}

/// The function that performs an HTTP request, e.g. `httpc.send_bits`.
pub type Send(error) =
  fn(Request(BitArray)) -> Result(Response(BitArray), error)

/// How to reach S3. Build one with `new` and the setters.
pub opaque type Client {
  Client(
    credentials: sigv4.Credentials,
    endpoint: Option(Endpoint),
    path_style: Option(Bool),
    tracer: Tracer,
    clock: Clock,
    send: fn(Request(BitArray)) -> Result(Response(BitArray), String),
  )
}

type Endpoint {
  Endpoint(scheme: http.Scheme, host: String, port: Option(Int), path: String)
}

/// A bucket on a client. Make one with `bucket`.
pub opaque type Bucket {
  Bucket(client: Client, name: String)
}

pub type Error {
  /// The request could not be sent or no response came back.
  Transport(reason: String)
  /// The object (or, for a request with no response body, whatever was
  /// asked for) does not exist.
  NotFound
  /// S3 refused the request, with its error code, such as `AccessDenied`,
  /// `NoSuchBucket` or `SlowDown`, and message.
  ServerError(status: Int, code: String, message: String)
  /// The response could not be understood.
  InvalidResponse(reason: String)
}

/// A client for AWS S3 in `region`, sending requests with `send`.
pub fn new(
  access_key_id access_key_id: String,
  secret_access_key secret_access_key: String,
  region region: String,
  send send: Send(e),
) -> Client {
  Client(
    credentials: sigv4.Credentials(
      access_key_id:,
      secret_access_key:,
      session_token: None,
      region:,
    ),
    endpoint: None,
    path_style: None,
    tracer: tracer.new(),
    clock: clock.system(),
    send: fn(req) { send(req) |> result.map_error(string.inspect) },
  )
}

/// Send requests to another S3-compatible service, such as
/// `"http://localhost:9000"` for MinIO or
/// `"https://<account>.r2.cloudflarestorage.com"` for R2. Requests then use
/// path style unless `path_style(False)` is set.
///
/// Panics if `url` isn't an absolute `http` or `https` URL.
pub fn endpoint(client: Client, url: String) -> Client {
  let parsed = {
    use parsed <- result.try(uri.parse(url))
    use scheme <- result.try(
      option.to_result(parsed.scheme, Nil)
      |> result.try(http.scheme_from_string),
    )
    use host <- result.try(option.to_result(parsed.host, Nil))
    let path = case string.ends_with(parsed.path, "/") {
      True -> string.drop_end(parsed.path, 1)
      False -> parsed.path
    }
    Ok(Endpoint(scheme:, host:, port: parsed.port, path:))
  }
  case parsed {
    Ok(endpoint) -> Client(..client, endpoint: Some(endpoint))
    Error(Nil) -> panic as { "s3.endpoint: not an http(s) URL: " <> url }
  }
}

/// Address buckets in the path (`host/bucket/key`) rather than the host
/// name (`bucket.host/key`).
pub fn path_style(client: Client, enabled: Bool) -> Client {
  Client(..client, path_style: Some(enabled))
}

/// The session token that comes with temporary credentials, such as those
/// from an instance or task role.
pub fn session_token(client: Client, token: Option(String)) -> Client {
  Client(
    ..client,
    credentials: sigv4.Credentials(..client.credentials, session_token: token),
  )
}

pub fn tracer(client: Client, tracer: Tracer) -> Client {
  Client(..client, tracer:)
}

/// The clock requests are signed with. Default `clock.system()`.
pub fn clock(client: Client, clock: Clock) -> Client {
  Client(..client, clock:)
}

/// The bucket `name` on this client.
pub fn bucket(client: Client, name: String) -> Bucket {
  Bucket(client:, name:)
}

pub fn bucket_name(bucket: Bucket) -> String {
  bucket.name
}

/// A one-line description of an error, for logs.
pub fn describe(error: Error) -> String {
  case error {
    Transport(reason) -> "request failed: " <> reason
    NotFound -> "not found"
    ServerError(status:, code:, message:) ->
      "S3 answered "
      <> int.to_string(status)
      <> case code {
        "" -> ""
        _ -> " " <> code
      }
      <> case message {
        "" -> ""
        _ -> ": " <> message
      }
    InvalidResponse(reason) -> "invalid response: " <> reason
  }
}

// --- Objects -------------------------------------------------------------------

/// How to store an object. Start from `put_options()`.
pub type PutOptions {
  PutOptions(
    content_type: Option(String),
    cache_control: Option(String),
    content_disposition: Option(String),
    /// Stored as `x-amz-meta-<name>` and returned with the object.
    metadata: List(#(String, String)),
  )
}

/// No content type (S3 uses `binary/octet-stream`), cache control,
/// disposition or metadata.
pub fn put_options() -> PutOptions {
  PutOptions(
    content_type: None,
    cache_control: None,
    content_disposition: None,
    metadata: [],
  )
}

/// What S3 knows about an object.
pub type ObjectInfo {
  ObjectInfo(
    /// Bytes: of the object from `head_object`, of the body (or range)
    /// from `get_object`.
    size: Int,
    content_type: String,
    /// As S3 sends it, in quotes.
    etag: String,
    last_modified: Option(Timestamp),
    /// Metadata stored with `PutOptions`, without the `x-amz-meta-` prefix.
    metadata: List(#(String, String)),
  )
}

pub type Object {
  Object(info: ObjectInfo, body: BitArray)
}

/// Store `body` under `key`, replacing any object there. Answers the new
/// object's ETag.
pub fn put_object(
  bucket: Bucket,
  key: String,
  body: BitArray,
  options: PutOptions,
) -> Result(String, Error) {
  let req =
    new_request(bucket, http.Put, Some(key), [])
    |> put_headers(options)
    |> request.set_body(body)
  use res <- result.map(run(bucket, "put_object", Some(key), req, []))
  header(res, "etag")
}

/// The object at `key`, or the bytes `#(first, last)` of it (inclusive).
pub fn get_object(
  bucket: Bucket,
  key: String,
  range range: Option(#(Int, Int)),
) -> Result(Object, Error) {
  let req = new_request(bucket, http.Get, Some(key), [])
  let req = case range {
    Some(#(first, last)) ->
      request.set_header(
        req,
        "range",
        "bytes=" <> int.to_string(first) <> "-" <> int.to_string(last),
      )
    None -> req
  }
  use res <- result.map(run(bucket, "get_object", Some(key), req, []))
  Object(info: info(res), body: res.body)
}

/// What S3 knows about the object at `key`, without its body.
pub fn head_object(bucket: Bucket, key: String) -> Result(ObjectInfo, Error) {
  let req = new_request(bucket, http.Head, Some(key), [])
  use res <- result.map(run(bucket, "head_object", Some(key), req, []))
  info(res)
}

/// Delete the object at `key`. Deleting an object that doesn't exist
/// succeeds.
pub fn delete_object(bucket: Bucket, key: String) -> Result(Nil, Error) {
  let req = new_request(bucket, http.Delete, Some(key), [])
  run(bucket, "delete_object", Some(key), req, []) |> result.replace(Nil)
}

/// A key that `delete_objects` could not delete.
pub type DeleteFailure {
  DeleteFailure(key: String, code: String, message: String)
}

/// Delete many objects, 1000 to a request. Answers the keys that could not
/// be deleted; keys that don't exist count as deleted.
pub fn delete_objects(
  bucket: Bucket,
  keys: List(String),
) -> Result(List(DeleteFailure), Error) {
  list.sized_chunk(keys, 1000)
  |> list.try_fold([], fn(failures, chunk) {
    use more <- result.map(delete_chunk(bucket, chunk))
    list.append(failures, more)
  })
}

fn delete_chunk(
  bucket: Bucket,
  keys: List(String),
) -> Result(List(DeleteFailure), Error) {
  let body =
    "<Delete><Quiet>true</Quiet>"
    <> string.concat(
      list.map(keys, fn(key) {
        "<Object><Key>" <> xml.escape(key) <> "</Key></Object>"
      }),
    )
    <> "</Delete>"
  let body = <<body:utf8>>
  let req =
    new_request(bucket, http.Post, None, [#("delete", "")])
    |> request.set_header("content-type", "application/xml")
    |> request.set_header("content-md5", md5_base64(body))
    |> request.set_body(body)
  use res <- result.try(
    run(bucket, "delete_objects", None, req, [
      #("count", meta.Int(list.length(keys))),
    ]),
  )
  use root <- result.map(document(res))
  xml.children(root, "Error")
  |> list.map(fn(error) {
    DeleteFailure(
      key: xml.child_text(error, "Key"),
      code: xml.child_text(error, "Code"),
      message: xml.child_text(error, "Message"),
    )
  })
}

/// Copy the object at `from_key` in `from` to `to_key` in `to`, which may
/// be the same bucket, with its content type and metadata. Answers the new
/// object's ETag.
pub fn copy_object(
  from from: Bucket,
  from_key from_key: String,
  to to: Bucket,
  to_key to_key: String,
) -> Result(String, Error) {
  let req =
    new_request(to, http.Put, Some(to_key), [])
    |> request.set_header(
      "x-amz-copy-source",
      "/" <> from.name <> "/" <> sigv4.encode_path(from_key),
    )
  use res <- result.try(
    run(to, "copy_object", Some(to_key), req, [
      #("source", meta.String(from.name <> "/" <> from_key)),
    ]),
  )
  // A copy can fail after S3 has answered 200: the error is in the body.
  use root <- result.try(document(res))
  case root.name {
    "Error" -> Error(document_error(res.status, root))
    _ -> Ok(xml.child_text(root, "ETag"))
  }
}

// --- Listing -------------------------------------------------------------------

/// What to list. Start from `list_options()`.
pub type ListOptions {
  ListOptions(
    /// Only keys starting with this.
    prefix: Option(String),
    /// Group keys that share a prefix up to this, usually `"/"`, into
    /// `Listing.prefixes`, like directories.
    delimiter: Option(String),
    /// At most this many keys (and prefixes) in a page; S3's limit and
    /// default is 1000.
    max_keys: Option(Int),
    /// The `next` token of the previous page.
    continuation: Option(String),
  )
}

pub fn list_options() -> ListOptions {
  ListOptions(prefix: None, delimiter: None, max_keys: None, continuation: None)
}

/// One page of a listing.
pub type Listing {
  Listing(
    objects: List(Entry),
    /// With a delimiter: the shared prefixes, such as `"photos/"`.
    prefixes: List(String),
    /// The token for the next page, when there is one.
    next: Option(String),
  )
}

pub type Entry {
  Entry(key: String, size: Int, etag: String, last_modified: Option(Timestamp))
}

/// A page of the bucket's keys, in order.
pub fn list_objects(
  bucket: Bucket,
  options: ListOptions,
) -> Result(Listing, Error) {
  let params =
    list.flatten([
      [#("list-type", "2")],
      option_param("prefix", options.prefix),
      option_param("delimiter", options.delimiter),
      option_param("max-keys", option.map(options.max_keys, int.to_string)),
      option_param("continuation-token", options.continuation),
    ])
  let req = new_request(bucket, http.Get, None, params)
  use res <- result.try(
    run(bucket, "list_objects", None, req, case options.prefix {
      Some(prefix) -> [#("prefix", meta.String(prefix))]
      None -> []
    }),
  )
  use root <- result.map(document(res))
  Listing(
    objects: xml.children(root, "Contents")
      |> list.map(fn(entry) {
        Entry(
          key: xml.child_text(entry, "Key"),
          size: int.parse(xml.child_text(entry, "Size")) |> result.unwrap(0),
          etag: xml.child_text(entry, "ETag"),
          last_modified: xml.child_text(entry, "LastModified")
            |> timestamp.parse_rfc3339
            |> option.from_result,
        )
      }),
    prefixes: xml.children(root, "CommonPrefixes")
      |> list.map(xml.child_text(_, "Prefix")),
    next: case xml.child_text(root, "IsTruncated") {
      "true" -> xml.optional_text(root, "NextContinuationToken")
      _ -> None
    },
  )
}

// --- Presigned URLs --------------------------------------------------------------

/// A URL anyone can `GET` the object at `key` from until `expires` has
/// passed (at most seven days), such as a download link.
pub fn presign_get(
  bucket: Bucket,
  key: String,
  expires expires: Duration,
) -> String {
  presign(bucket, http.Get, key, expires)
}

/// A URL anyone can `PUT` an object to at `key` until `expires` has passed
/// (at most seven days), such as for uploading straight from a browser.
pub fn presign_put(
  bucket: Bucket,
  key: String,
  expires expires: Duration,
) -> String {
  presign(bucket, http.Put, key, expires)
}

fn presign(
  bucket: Bucket,
  method: http.Method,
  key: String,
  expires: Duration,
) -> String {
  let seconds = float.truncate(duration.to_seconds(expires))
  sigv4.presign(
    new_request(bucket, method, Some(key), []),
    bucket.client.credentials,
    clock.now(bucket.client.clock),
    int.clamp(seconds, 1, 604_800),
  )
}

// --- Multipart uploads ---------------------------------------------------------

/// An upload in progress. Parts are uploaded with `upload_part`, then
/// joined with `complete_multipart_upload` or thrown away with
/// `abort_multipart_upload`.
pub type Upload {
  Upload(bucket: Bucket, key: String, id: String)
}

pub type Part {
  /// `number` from 1; `etag` as S3 answered it.
  Part(number: Int, etag: String)
}

/// The smallest part S3 accepts, except for the last: 5 MiB.
pub const min_part_size = 5_242_880

/// Start uploading an object in parts, for objects too large to send in
/// one request (S3's limit is 5 GiB) or to send in parallel.
pub fn create_multipart_upload(
  bucket: Bucket,
  key: String,
  options: PutOptions,
) -> Result(Upload, Error) {
  let req =
    new_request(bucket, http.Post, Some(key), [#("uploads", "")])
    |> put_headers(options)
  use res <- result.try(
    run(bucket, "create_multipart_upload", Some(key), req, []),
  )
  use root <- result.try(document(res))
  case xml.child_text(root, "UploadId") {
    "" -> Error(InvalidResponse("no UploadId"))
    id -> Ok(Upload(bucket:, key:, id:))
  }
}

/// Upload part `number` (from 1 to 10,000). Every part but the last must
/// be at least `min_part_size` bytes.
pub fn upload_part(
  upload: Upload,
  number: Int,
  body: BitArray,
) -> Result(Part, Error) {
  let req =
    new_request(upload.bucket, http.Put, Some(upload.key), [
      #("partNumber", int.to_string(number)),
      #("uploadId", upload.id),
    ])
    |> request.set_body(body)
  use res <- result.map(
    run(upload.bucket, "upload_part", Some(upload.key), req, [
      #("part", meta.Int(number)),
    ]),
  )
  Part(number:, etag: header(res, "etag"))
}

/// Join the parts, in order of their numbers, into the object. Answers its
/// ETag.
pub fn complete_multipart_upload(
  upload: Upload,
  parts: List(Part),
) -> Result(String, Error) {
  let body =
    "<CompleteMultipartUpload>"
    <> list.sort(parts, fn(a, b) { int.compare(a.number, b.number) })
    |> list.map(fn(part) {
      "<Part><PartNumber>"
      <> int.to_string(part.number)
      <> "</PartNumber><ETag>"
      <> xml.escape(part.etag)
      <> "</ETag></Part>"
    })
    |> string.concat
    <> "</CompleteMultipartUpload>"
  let req =
    new_request(upload.bucket, http.Post, Some(upload.key), [
      #("uploadId", upload.id),
    ])
    |> request.set_header("content-type", "application/xml")
    |> request.set_body(<<body:utf8>>)
  use res <- result.try(
    run(upload.bucket, "complete_multipart_upload", Some(upload.key), req, [
      #("parts", meta.Int(list.length(parts))),
    ]),
  )
  // Like a copy, completing can fail after a 200.
  use root <- result.try(document(res))
  case root.name {
    "Error" -> Error(document_error(res.status, root))
    _ -> Ok(xml.child_text(root, "ETag"))
  }
}

/// Throw away an upload and the parts sent so far.
pub fn abort_multipart_upload(upload: Upload) -> Result(Nil, Error) {
  let req =
    new_request(upload.bucket, http.Delete, Some(upload.key), [
      #("uploadId", upload.id),
    ])
  run(upload.bucket, "abort_multipart_upload", Some(upload.key), req, [])
  |> result.replace(Nil)
}

/// Store `body` with one `put_object` if it is at most `part_size` bytes,
/// or else as a multipart upload of `part_size` parts (at least
/// `min_part_size`), sent one after another. An upload that fails is
/// aborted. Answers the object's ETag.
pub fn put_object_in_parts(
  bucket: Bucket,
  key: String,
  body: BitArray,
  options: PutOptions,
  part_size part_size: Int,
) -> Result(String, Error) {
  let part_size = int.max(part_size, min_part_size)
  case bit_array.byte_size(body) <= part_size {
    True -> put_object(bucket, key, body, options)
    False -> {
      use upload <- result.try(create_multipart_upload(bucket, key, options))
      {
        use parts <- result.try(upload_parts(upload, body, part_size, 1, []))
        complete_multipart_upload(upload, parts)
      }
      |> result.map_error(fn(error) {
        let _ = abort_multipart_upload(upload)
        error
      })
    }
  }
}

fn upload_parts(
  upload: Upload,
  body: BitArray,
  part_size: Int,
  number: Int,
  acc: List(Part),
) -> Result(List(Part), Error) {
  let size = bit_array.byte_size(body)
  case size {
    0 -> Ok(list.reverse(acc))
    _ -> {
      let take = int.min(size, part_size)
      let assert Ok(chunk) = bit_array.slice(body, 0, take)
      let assert Ok(rest) = bit_array.slice(body, take, size - take)
      use part <- result.try(upload_part(upload, number, chunk))
      upload_parts(upload, rest, part_size, number + 1, [part, ..acc])
    }
  }
}

// --- Buckets -------------------------------------------------------------------

/// Create the bucket, in the client's region.
pub fn create_bucket(bucket: Bucket) -> Result(Nil, Error) {
  let region = bucket.client.credentials.region
  let req = new_request(bucket, http.Put, None, [])
  let req = case region {
    "us-east-1" -> req
    _ ->
      request.set_body(req, <<
        "<CreateBucketConfiguration><LocationConstraint>":utf8,
        xml.escape(region):utf8,
        "</LocationConstraint></CreateBucketConfiguration>":utf8,
      >>)
  }
  run(bucket, "create_bucket", None, req, []) |> result.replace(Nil)
}

/// Delete the bucket, which must be empty.
pub fn delete_bucket(bucket: Bucket) -> Result(Nil, Error) {
  let req = new_request(bucket, http.Delete, None, [])
  run(bucket, "delete_bucket", None, req, []) |> result.replace(Nil)
}

// --- Requests ------------------------------------------------------------------

/// An unsigned request for `key` (or the bucket itself) with `params`.
fn new_request(
  bucket: Bucket,
  method: http.Method,
  key: Option(String),
  params: List(#(String, String)),
) -> Request(BitArray) {
  let client = bucket.client
  let path_style = option.unwrap(client.path_style, client.endpoint != None)
  let Endpoint(scheme:, host:, port:, path: base) = case client.endpoint {
    Some(endpoint) -> endpoint
    None ->
      Endpoint(
        scheme: http.Https,
        host: "s3." <> client.credentials.region <> ".amazonaws.com",
        port: None,
        path: "",
      )
  }
  let host = case path_style {
    True -> host
    False -> bucket.name <> "." <> host
  }
  let bucket_path = case path_style {
    True -> "/" <> sigv4.encode(bucket.name)
    False -> ""
  }
  let path = case key, path_style {
    Some(key), _ -> base <> bucket_path <> "/" <> sigv4.encode_path(key)
    None, True -> base <> bucket_path
    None, False -> base <> "/"
  }
  request.Request(
    method:,
    headers: [],
    body: <<>>,
    scheme:,
    host:,
    port:,
    path:,
    query: case params {
      [] -> None
      _ -> Some(sigv4.query_string(params))
    },
  )
}

fn put_headers(
  req: Request(BitArray),
  options: PutOptions,
) -> Request(BitArray) {
  let set = fn(req, name, value) {
    case value {
      Some(value) -> request.set_header(req, name, value)
      None -> req
    }
  }
  let req =
    req
    |> set("content-type", options.content_type)
    |> set("cache-control", options.cache_control)
    |> set("content-disposition", options.content_disposition)
  list.fold(options.metadata, req, fn(req, entry) {
    request.set_header(req, "x-amz-meta-" <> string.lowercase(entry.0), entry.1)
  })
}

/// Sign and send a request, tracing it. Answers 2xx responses; others
/// become errors.
fn run(
  bucket: Bucket,
  operation: String,
  key: Option(String),
  req: Request(BitArray),
  extra: Meta,
) -> Result(Response(BitArray), Error) {
  let client = bucket.client
  let signed =
    sigv4.sign(
      req,
      client.credentials,
      clock.now(client.clock),
      sigv4.sha256_hex(req.body),
    )
  let parent = tracer.current()
  let at = timestamp.system_time()
  let started = monotonic_ns()
  let result = case client.send(signed) {
    Error(reason) -> Error(Transport(reason))
    Ok(res) if res.status >= 200 && res.status < 300 -> Ok(res)
    Ok(res) -> Error(response_error(res))
  }
  let elapsed = duration.nanoseconds(monotonic_ns() - started)
  tracer.emit(client.tracer, fn() {
    let status = case result {
      Ok(res) -> [#("status", meta.Int(res.status))]
      Error(ServerError(status:, ..)) -> [#("status", meta.Int(status))]
      Error(NotFound) -> [#("status", meta.Int(404))]
      Error(_) -> []
    }
    let bytes = case req.method, result {
      http.Get, Ok(res) -> bit_array.byte_size(res.body)
      _, _ -> bit_array.byte_size(req.body)
    }
    tracer.Span(
      source: "gloss.s3",
      name: operation,
      at:,
      meta: list.flatten([
        [#("bucket", meta.String(bucket.name))],
        case key {
          Some(key) -> [#("key", meta.String(key))]
          None -> []
        },
        [#("bytes", meta.Int(bytes))],
        status,
        extra,
      ]),
      duration: elapsed,
      error: case result {
        Ok(_) -> None
        // A missing object is an answer, not a failure of the request.
        Error(NotFound) -> None
        Error(error) -> Some(describe(error))
      },
      trace: case parent {
        Some(parent) -> tracer.child(parent)
        None -> tracer.root()
      },
      parent_span_id: option.map(parent, fn(parent) { parent.span_id }),
    )
  })
  result
}

fn response_error(res: Response(BitArray)) -> Error {
  case xml.parse(res.body) {
    Ok(root) -> document_error(res.status, root)
    Error(_) ->
      case res.status {
        404 -> NotFound
        status -> ServerError(status:, code: "", message: "")
      }
  }
}

fn document_error(status: Int, root: xml.Element) -> Error {
  let code = xml.child_text(root, "Code")
  case code {
    "NoSuchKey" -> NotFound
    _ ->
      ServerError(
        status: case status {
          200 -> 500
          _ -> status
        },
        code:,
        message: xml.child_text(root, "Message"),
      )
  }
}

fn document(res: Response(BitArray)) -> Result(xml.Element, Error) {
  xml.parse(res.body) |> result.map_error(InvalidResponse)
}

fn info(res: Response(BitArray)) -> ObjectInfo {
  ObjectInfo(
    size: header(res, "content-length")
      |> int.parse
      |> result.unwrap(bit_array.byte_size(res.body)),
    content_type: header(res, "content-type"),
    etag: header(res, "etag"),
    last_modified: http_date(header(res, "last-modified")),
    metadata: list.filter_map(res.headers, fn(h) {
      case string.lowercase(h.0) {
        "x-amz-meta-" <> name -> Ok(#(name, h.1))
        _ -> Error(Nil)
      }
    }),
  )
}

fn header(res: Response(BitArray), name: String) -> String {
  response.get_header(res, name) |> result.unwrap("")
}

fn option_param(
  name: String,
  value: Option(String),
) -> List(#(String, String)) {
  case value {
    Some(value) -> [#(name, value)]
    None -> []
  }
}

fn md5_base64(body: BitArray) -> String {
  crypto.hash(crypto.Md5, body) |> bit_array.base64_encode(True)
}

/// An IMF-fixdate such as `Wed, 12 Oct 2009 17:50:00 GMT`.
fn http_date(text: String) -> Option(Timestamp) {
  case string.split(text, " ") {
    [_, day, month, year, time, "GMT"] -> {
      let parsed = {
        use day <- result.try(int.parse(day))
        use month <- result.try(month_number(month))
        use month <- result.try(calendar.month_from_int(month))
        use year <- result.try(int.parse(year))
        use #(hours, minutes, seconds) <- result.try(
          case string.split(time, ":") {
            [h, m, s] -> {
              use h <- result.try(int.parse(h))
              use m <- result.try(int.parse(m))
              use s <- result.map(int.parse(s))
              #(h, m, s)
            }
            _ -> Error(Nil)
          },
        )
        Ok(timestamp.from_calendar(
          calendar.Date(year:, month:, day:),
          calendar.TimeOfDay(hours:, minutes:, seconds:, nanoseconds: 0),
          calendar.utc_offset,
        ))
      }
      option.from_result(parsed)
    }
    _ -> None
  }
}

fn month_number(name: String) -> Result(Int, Nil) {
  case name {
    "Jan" -> Ok(1)
    "Feb" -> Ok(2)
    "Mar" -> Ok(3)
    "Apr" -> Ok(4)
    "May" -> Ok(5)
    "Jun" -> Ok(6)
    "Jul" -> Ok(7)
    "Aug" -> Ok(8)
    "Sep" -> Ok(9)
    "Oct" -> Ok(10)
    "Nov" -> Ok(11)
    "Dec" -> Ok(12)
    _ -> Error(Nil)
  }
}

@external(erlang, "gloss@s3_ffi", "monotonic_ns")
fn monotonic_ns() -> Int

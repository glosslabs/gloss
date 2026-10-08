//// The client against a fake `send`: how requests are addressed and signed,
//// and how responses and errors are read.

import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gloss/clock
import gloss/meta
import gloss/s3
import gloss/tracer

fn client(
  sent: Subject(Request(BitArray)),
  answer: fn(Request(BitArray)) -> Response(BitArray),
) -> s3.Client {
  s3.new(
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "secret",
    region: "eu-west-2",
    send: fn(req) {
      process.send(sent, req)
      Ok(answer(req))
    },
  )
}

fn ok(_req) -> Response(BitArray) {
  response.new(200) |> response.set_body(<<>>)
}

fn xml_response(status: Int, body: String) -> Response(BitArray) {
  response.new(status)
  |> response.set_header("content-type", "application/xml")
  |> response.set_body(<<body:utf8>>)
}

pub fn aws_uses_virtual_hosted_https_test() {
  let sent = process.new_subject()
  let bucket = client(sent, ok) |> s3.bucket("photos")
  let assert Ok(_) =
    s3.put_object(bucket, "2026/a b.jpg", <<"x":utf8>>, s3.put_options())
  let assert Ok(req) = process.receive(sent, 0)
  assert req.scheme == http.Https
  assert req.host == "photos.s3.eu-west-2.amazonaws.com"
  assert req.path == "/2026/a%20b.jpg"
  assert req.method == http.Put
  let assert Ok(authorization) = request.get_header(req, "authorization")
  assert string.contains(authorization, "/eu-west-2/s3/aws4_request")
  // The body's hash is signed.
  assert request.get_header(req, "x-amz-content-sha256")
    == Ok("2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881")
}

pub fn an_endpoint_uses_path_style_test() {
  let sent = process.new_subject()
  let c = client(sent, ok) |> s3.endpoint("http://localhost:9000/")
  let assert Ok(_) = s3.delete_object(s3.bucket(c, "photos"), "k")
  let assert Ok(req) = process.receive(sent, 0)
  assert req.scheme == http.Http
  assert req.host == "localhost"
  assert req.port == Some(9000)
  assert req.path == "/photos/k"

  // ...unless told otherwise.
  let c = c |> s3.path_style(False)
  let assert Ok(_) = s3.delete_object(s3.bucket(c, "photos"), "k")
  let assert Ok(req) = process.receive(sent, 0)
  assert req.host == "photos.localhost"
  assert req.path == "/k"
}

pub fn put_options_become_headers_test() {
  let sent = process.new_subject()
  let bucket = client(sent, ok) |> s3.bucket("b")
  let options =
    s3.PutOptions(
      content_type: Some("image/png"),
      cache_control: Some("max-age=60"),
      content_disposition: None,
      metadata: [#("Owner", "7")],
    )
  let assert Ok(_) = s3.put_object(bucket, "k", <<>>, options)
  let assert Ok(req) = process.receive(sent, 0)
  assert request.get_header(req, "content-type") == Ok("image/png")
  assert request.get_header(req, "cache-control") == Ok("max-age=60")
  assert request.get_header(req, "x-amz-meta-owner") == Ok("7")
}

pub fn get_object_reads_the_body_and_headers_test() {
  let sent = process.new_subject()
  let bucket =
    client(sent, fn(_) {
      response.new(206)
      |> response.set_header("content-type", "text/plain")
      |> response.set_header("content-length", "5")
      |> response.set_header("etag", "\"abc\"")
      |> response.set_header("last-modified", "Wed, 12 Oct 2009 17:50:00 GMT")
      |> response.set_header("x-amz-meta-owner", "7")
      |> response.set_body(<<"hello":utf8>>)
    })
    |> s3.bucket("b")
  let assert Ok(object) = s3.get_object(bucket, "k", range: Some(#(0, 4)))
  let assert Ok(req) = process.receive(sent, 0)
  assert request.get_header(req, "range") == Ok("bytes=0-4")
  assert object.body == <<"hello":utf8>>
  assert object.info.size == 5
  assert object.info.etag == "\"abc\""
  assert object.info.content_type == "text/plain"
  assert object.info.metadata == [#("owner", "7")]
  let assert Ok(expected) = timestamp.parse_rfc3339("2009-10-12T17:50:00Z")
  assert object.info.last_modified == Some(expected)
}

pub fn errors_are_read_from_the_body_test() {
  let sent = process.new_subject()
  let answer = fn(req: Request(BitArray)) {
    case req.path {
      "/missing" ->
        xml_response(
          404,
          "<Error><Code>NoSuchKey</Code><Message>gone</Message></Error>",
        )
      "/secret" ->
        xml_response(
          403,
          "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>",
        )
      _ -> response.new(404) |> response.set_body(<<>>)
    }
  }
  let bucket = client(sent, answer) |> s3.bucket("b")
  assert s3.get_object(bucket, "missing", range: None) == Error(s3.NotFound)
  assert s3.get_object(bucket, "secret", range: None)
    == Error(s3.ServerError(
      status: 403,
      code: "AccessDenied",
      message: "Access Denied",
    ))
  // HEAD responses have no body.
  assert s3.head_object(bucket, "other") == Error(s3.NotFound)

  let failing =
    s3.new(
      access_key_id: "a",
      secret_access_key: "b",
      region: "us-east-1",
      send: fn(_) { Error("econnrefused") },
    )
    |> s3.bucket("b")
  let assert Error(s3.Transport(reason)) = s3.delete_object(failing, "k")
  assert string.contains(reason, "econnrefused")
}

pub fn a_copy_can_fail_after_a_200_test() {
  let sent = process.new_subject()
  let bucket =
    client(sent, fn(_) {
      xml_response(
        200,
        "<Error><Code>InternalError</Code><Message>try again</Message></Error>",
      )
    })
    |> s3.bucket("b")
  assert s3.copy_object(from: bucket, from_key: "a b", to: bucket, to_key: "c")
    == Error(s3.ServerError(
      status: 500,
      code: "InternalError",
      message: "try again",
    ))
  let assert Ok(req) = process.receive(sent, 0)
  assert request.get_header(req, "x-amz-copy-source") == Ok("/b/a%20b")
}

pub fn listings_are_parsed_test() {
  let sent = process.new_subject()
  let bucket =
    client(sent, fn(_) {
      xml_response(
        200,
        "<ListBucketResult><Name>b</Name><IsTruncated>true</IsTruncated>
          <NextContinuationToken>tok</NextContinuationToken>
          <Contents><Key>a.txt</Key><Size>3</Size><ETag>\"e\"</ETag>
            <LastModified>2026-10-08T10:00:00.000Z</LastModified></Contents>
          <CommonPrefixes><Prefix>photos/</Prefix></CommonPrefixes>
        </ListBucketResult>",
      )
    })
    |> s3.bucket("b")
  let options =
    s3.ListOptions(
      ..s3.list_options(),
      prefix: Some("a b"),
      delimiter: Some("/"),
      max_keys: Some(10),
    )
  let assert Ok(listing) = s3.list_objects(bucket, options)
  let assert Ok(req) = process.receive(sent, 0)
  assert req.query == Some("delimiter=%2F&list-type=2&max-keys=10&prefix=a%20b")
  let assert [entry] = listing.objects
  assert entry.key == "a.txt"
  assert entry.size == 3
  assert entry.etag == "\"e\""
  let assert Ok(at) = timestamp.parse_rfc3339("2026-10-08T10:00:00Z")
  assert entry.last_modified == Some(at)
  assert listing.prefixes == ["photos/"]
  assert listing.next == Some("tok")
}

pub fn delete_objects_sends_a_signed_md5_test() {
  let sent = process.new_subject()
  let bucket =
    client(sent, fn(_) {
      xml_response(
        200,
        "<DeleteResult><Error><Key>b</Key><Code>AccessDenied</Code><Message>no</Message></Error></DeleteResult>",
      )
    })
    |> s3.bucket("b")
  let assert Ok(failures) = s3.delete_objects(bucket, ["a", "b & c"])
  assert failures
    == [s3.DeleteFailure(key: "b", code: "AccessDenied", message: "no")]
  let assert Ok(req) = process.receive(sent, 0)
  assert req.method == http.Post
  assert req.query == Some("delete")
  let assert Ok(body) = bit_array.to_string(req.body)
  assert string.contains(body, "<Key>b &amp; c</Key>")
  let assert Ok(_) = request.get_header(req, "content-md5")
  let assert Ok(authorization) = request.get_header(req, "authorization")
  assert string.contains(authorization, "content-md5")

  // More than 1000 keys go in several requests.
  let keys = list.repeat("k", 2500)
  let assert Ok(_) = s3.delete_objects(bucket, keys)
  assert list.length(drain(sent)) == 3
}

pub fn presigned_urls_use_the_clock_test() {
  let sent = process.new_subject()
  let assert Ok(at) = timestamp.parse_rfc3339("2026-10-08T10:00:00Z")
  let bucket =
    client(sent, ok)
    |> s3.clock(clock.fixed(at))
    |> s3.endpoint("http://localhost:9000")
    |> s3.bucket("b")
  let url = s3.presign_get(bucket, "a b.txt", expires: duration.minutes(10))
  assert string.starts_with(url, "http://localhost:9000/b/a%20b.txt?")
  assert string.contains(url, "X-Amz-Date=20261008T100000Z")
  assert string.contains(url, "X-Amz-Expires=600")
  assert string.contains(url, "&X-Amz-Signature=")
  // Nothing is sent to make one.
  assert process.receive(sent, 0) == Error(Nil)
  // At most seven days.
  assert string.contains(
    s3.presign_put(bucket, "k", expires: duration.hours(24 * 30)),
    "X-Amz-Expires=604800",
  )
}

pub fn requests_are_traced_under_the_current_span_test() {
  let sent = process.new_subject()
  let events = process.new_subject()
  let bucket =
    client(sent, fn(_) {
      xml_response(
        403,
        "<Error><Code>AccessDenied</Code><Message>no</Message></Error>",
      )
    })
    |> s3.tracer(tracer.new() |> tracer.handle(process.send(events, _)))
    |> s3.bucket("b")
  let parent = tracer.root()
  let _ =
    tracer.with_current(parent, fn() {
      s3.put_object(bucket, "k", <<"abc":utf8>>, s3.put_options())
    })
  let assert Ok(tracer.Span(
    source: "gloss.s3",
    name: "put_object",
    meta:,
    error: Some(_),
    trace:,
    parent_span_id: Some(parent_id),
    ..,
  )) = process.receive(events, 0)
  assert parent_id == parent.span_id
  assert trace.trace_id == parent.trace_id
  assert list.contains(meta, #("bucket", meta.String("b")))
  assert list.contains(meta, #("key", meta.String("k")))
  assert list.contains(meta, #("bytes", meta.Int(3)))
  assert list.contains(meta, #("status", meta.Int(403)))
}

pub fn multipart_uploads_in_parts_test() {
  let sent = process.new_subject()
  let answer = fn(req: Request(BitArray)) {
    case req.method, req.query {
      http.Post, Some("uploads") ->
        xml_response(
          200,
          "<InitiateMultipartUploadResult><UploadId>up1</UploadId></InitiateMultipartUploadResult>",
        )
      http.Put, Some(_) ->
        response.new(200)
        |> response.set_header("etag", "\"p\"")
        |> response.set_body(<<>>)
      http.Post, Some(_) ->
        xml_response(
          200,
          "<CompleteMultipartUploadResult><ETag>\"whole-2\"</ETag></CompleteMultipartUploadResult>",
        )
      _, _ -> ok(req)
    }
  }
  let bucket = client(sent, answer) |> s3.bucket("b")
  let body = <<0:size({ s3.min_part_size + 10 } * 8)>>
  let assert Ok(etag) =
    s3.put_object_in_parts(bucket, "big", body, s3.put_options(), part_size: 1)
  assert etag == "\"whole-2\""
  let requests = drain(sent)
  assert list.map(requests, fn(r) { #(r.method, r.query) })
    == [
      #(http.Post, Some("uploads")),
      #(http.Put, Some("partNumber=1&uploadId=up1")),
      #(http.Put, Some("partNumber=2&uploadId=up1")),
      #(http.Post, Some("uploadId=up1")),
    ]
  let assert [_, first, second, complete] = requests
  assert bit_array.byte_size(first.body) == s3.min_part_size
  assert bit_array.byte_size(second.body) == 10
  let assert Ok(xml) = bit_array.to_string(complete.body)
  assert string.contains(
    xml,
    "<Part><PartNumber>2</PartNumber><ETag>&quot;p&quot;</ETag></Part>",
  )

  // Small bodies go in one request.
  let assert Ok(_) =
    s3.put_object_in_parts(
      bucket,
      "small",
      <<1, 2, 3>>,
      s3.put_options(),
      part_size: s3.min_part_size,
    )
  assert list.map(drain(sent), fn(r) { r.method }) == [http.Put]
}

pub fn a_failed_part_aborts_the_upload_test() {
  let sent = process.new_subject()
  let answer = fn(req: Request(BitArray)) {
    case req.method, req.query {
      http.Post, Some("uploads") ->
        xml_response(
          200,
          "<InitiateMultipartUploadResult><UploadId>up1</UploadId></InitiateMultipartUploadResult>",
        )
      http.Put, _ ->
        xml_response(500, "<Error><Code>InternalError</Code></Error>")
      _, _ -> response.new(204) |> response.set_body(<<>>)
    }
  }
  let bucket = client(sent, answer) |> s3.bucket("b")
  let body = <<0:size({ s3.min_part_size + 1 } * 8)>>
  let assert Error(s3.ServerError(code: "InternalError", ..)) =
    s3.put_object_in_parts(bucket, "big", body, s3.put_options(), part_size: 0)
  let methods = drain(sent) |> list.map(fn(r) { r.method })
  assert methods == [http.Post, http.Put, http.Delete]
}

fn drain(subject: Subject(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(x) -> [x, ..drain(subject)]
    Error(Nil) -> []
  }
}

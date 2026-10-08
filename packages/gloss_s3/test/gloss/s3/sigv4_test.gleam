//// The signing examples from the AWS documentation: "Signature Calculations
//// for the Authorization Header: Transferring Payload in a Single Chunk"
//// and "Query String Authentication", for `examplebucket` in us-east-1 at
//// 2013-05-24T00:00:00Z.

import gleam/http
import gleam/http/request.{type Request}
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import gloss/s3/internal/sigv4

const empty_hash =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

fn credentials() -> sigv4.Credentials {
  sigv4.Credentials(
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    session_token: None,
    region: "us-east-1",
  )
}

fn at() {
  let assert Ok(at) = timestamp.parse_rfc3339("2013-05-24T00:00:00Z")
  at
}

fn example(method: http.Method, path: String, query) -> Request(BitArray) {
  request.Request(
    method:,
    headers: [],
    body: <<>>,
    scheme: http.Https,
    host: "examplebucket.s3.amazonaws.com",
    port: None,
    path:,
    query:,
  )
}

fn signature(req: Request(BitArray)) -> String {
  let assert Ok(authorization) = request.get_header(req, "authorization")
  let assert Ok(#(_, signature)) =
    string.split_once(authorization, "Signature=")
  signature
}

fn signed_headers(req: Request(BitArray)) -> String {
  let assert Ok(authorization) = request.get_header(req, "authorization")
  let assert Ok(#(_, rest)) = string.split_once(authorization, "SignedHeaders=")
  let assert Ok(#(names, _)) = string.split_once(rest, ",")
  names
}

pub fn get_object_test() {
  let req =
    example(http.Get, "/test.txt", None)
    |> request.set_header("range", "bytes=0-9")
  assert sigv4.canonical_request(
      http.Get,
      "/test.txt",
      [],
      [
        #("host", "examplebucket.s3.amazonaws.com"),
        #("range", "bytes=0-9"),
        #("x-amz-content-sha256", empty_hash),
        #("x-amz-date", "20130524T000000Z"),
      ],
      empty_hash,
    )
    == "GET
/test.txt

host:examplebucket.s3.amazonaws.com
range:bytes=0-9
x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
x-amz-date:20130524T000000Z

host;range;x-amz-content-sha256;x-amz-date
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  let signed = sigv4.sign(req, credentials(), at(), empty_hash)
  assert signed_headers(signed) == "host;range;x-amz-content-sha256;x-amz-date"
  assert signature(signed)
    == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
  let assert Ok(authorization) = request.get_header(signed, "authorization")
  assert string.starts_with(
    authorization,
    "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request",
  )
}

pub fn put_object_test() {
  let body = <<"Welcome to Amazon S3.":utf8>>
  let hash = sigv4.sha256_hex(body)
  assert hash
    == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
  let req =
    example(http.Put, "/" <> sigv4.encode_path("test$file.text"), None)
    |> request.set_header("date", "Fri, 24 May 2013 00:00:00 GMT")
    |> request.set_header("x-amz-storage-class", "REDUCED_REDUNDANCY")
    |> request.set_body(body)
  assert req.path == "/test%24file.text"
  let signed = sigv4.sign(req, credentials(), at(), hash)
  assert signed_headers(signed)
    == "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class"
  assert signature(signed)
    == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
}

pub fn get_bucket_lifecycle_test() {
  let req = example(http.Get, "/", Some("lifecycle"))
  assert signature(sigv4.sign(req, credentials(), at(), empty_hash))
    == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
}

pub fn list_objects_test() {
  let req =
    example(
      http.Get,
      "/",
      Some(sigv4.query_string([#("prefix", "J"), #("max-keys", "2")])),
    )
  assert req.query == Some("max-keys=2&prefix=J")
  assert signature(sigv4.sign(req, credentials(), at(), empty_hash))
    == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
}

pub fn presigned_url_test() {
  let url =
    sigv4.presign(
      example(http.Get, "/test.txt", None),
      credentials(),
      at(),
      86_400,
    )
  assert url
    == "https://examplebucket.s3.amazonaws.com/test.txt"
    <> "?X-Amz-Algorithm=AWS4-HMAC-SHA256"
    <> "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
    <> "&X-Amz-Date=20130524T000000Z"
    <> "&X-Amz-Expires=86400"
    <> "&X-Amz-SignedHeaders=host"
    <> "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
}

pub fn session_tokens_are_signed_test() {
  let creds =
    sigv4.Credentials(..credentials(), session_token: Some("token/with+chars"))
  let signed =
    sigv4.sign(example(http.Get, "/test.txt", None), creds, at(), empty_hash)
  assert request.get_header(signed, "x-amz-security-token")
    == Ok("token/with+chars")
  assert string.contains(signed_headers(signed), "x-amz-security-token")
  let url = sigv4.presign(example(http.Get, "/test.txt", None), creds, at(), 60)
  assert string.contains(url, "X-Amz-Security-Token=token%2Fwith%2Bchars")
}

pub fn encoding_test() {
  assert sigv4.encode("a b/c~d_e.f-g*h") == "a%20b%2Fc~d_e.f-g%2Ah"
  assert sigv4.encode_path("photos/2026 trip/é.jpg")
    == "photos/2026%20trip/%C3%A9.jpg"
  // A parameter with no value is sent bare but signed as `name=`.
  assert sigv4.query_string([#("uploads", "")]) == "uploads"
  assert sigv4.canonical_query(sigv4.parse_query(Some("uploads"))) == "uploads="
}

pub fn non_default_ports_are_part_of_the_host_test() {
  let req =
    request.Request(
      ..example(http.Get, "/", None),
      scheme: http.Http,
      host: "localhost",
      port: Some(9000),
    )
  assert sigv4.host(req) == "localhost:9000"
  assert sigv4.host(request.Request(..req, port: Some(80))) == "localhost"
}

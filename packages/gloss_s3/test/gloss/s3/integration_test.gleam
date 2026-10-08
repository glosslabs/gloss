//// Against a real S3-compatible server, when `GLOSS_TEST_S3_ENDPOINT` is set:
////
//// ```sh
//// docker run -d --name gloss-s3-test -p 9010:9000 \
////   -e RUSTFS_ACCESS_KEY=gloss -e RUSTFS_SECRET_KEY=glosssecret rustfs/rustfs
//// GLOSS_TEST_S3_ENDPOINT=http://localhost:9010 gleam test
//// ```
////
//// `GLOSS_TEST_S3_ACCESS_KEY`, `GLOSS_TEST_S3_SECRET_KEY` and `GLOSS_TEST_S3_REGION` default to
//// `gloss`, `glosssecret` and `us-east-1`.

import envoy
import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gloss/s3

fn with_bucket(test_: fn(s3.Bucket) -> Nil) -> Nil {
  case envoy.get("GLOSS_TEST_S3_ENDPOINT") {
    Error(Nil) -> Nil
    Ok(endpoint) -> {
      let env = fn(name, default) { envoy.get(name) |> result.unwrap(default) }
      let bucket =
        s3.new(
          access_key_id: env("GLOSS_TEST_S3_ACCESS_KEY", "gloss"),
          secret_access_key: env("GLOSS_TEST_S3_SECRET_KEY", "glosssecret"),
          region: env("GLOSS_TEST_S3_REGION", "us-east-1"),
          send: httpc.send_bits,
        )
        |> s3.endpoint(endpoint)
        |> s3.bucket("gloss-test-" <> int.to_string(unique()))
      let assert Ok(Nil) = s3.create_bucket(bucket)
      test_(bucket)
      empty(bucket, None)
      let assert Ok(Nil) = s3.delete_bucket(bucket)
      Nil
    }
  }
}

fn empty(bucket: s3.Bucket, continuation) -> Nil {
  let assert Ok(page) =
    s3.list_objects(bucket, s3.ListOptions(..s3.list_options(), continuation:))
  let assert Ok([]) =
    s3.delete_objects(bucket, list.map(page.objects, fn(o) { o.key }))
  case page.next {
    Some(next) -> empty(bucket, Some(next))
    None -> Nil
  }
}

pub fn objects_round_trip_test() {
  use bucket <- with_bucket
  let key = "notes/café menu.txt"
  let options =
    s3.PutOptions(
      ..s3.put_options(),
      content_type: Some("text/plain"),
      metadata: [#("owner", "7")],
    )
  let assert Ok(etag) =
    s3.put_object(bucket, key, <<"hello, world":utf8>>, options)
  assert etag != ""

  let assert Ok(object) = s3.get_object(bucket, key, range: None)
  assert object.body == <<"hello, world":utf8>>
  assert object.info.content_type == "text/plain"
  assert object.info.etag == etag
  assert object.info.metadata == [#("owner", "7")]
  assert object.info.last_modified != None

  let assert Ok(part) = s3.get_object(bucket, key, range: Some(#(7, 11)))
  assert part.body == <<"world":utf8>>

  let assert Ok(info) = s3.head_object(bucket, key)
  assert info.size == 12

  let assert Ok(_) =
    s3.copy_object(from: bucket, from_key: key, to: bucket, to_key: "copy")
  let assert Ok(copy) = s3.get_object(bucket, "copy", range: None)
  assert copy.body == <<"hello, world":utf8>>

  let assert Ok(Nil) = s3.delete_object(bucket, key)
  assert s3.get_object(bucket, key, range: None) == Error(s3.NotFound)
  assert s3.head_object(bucket, key) == Error(s3.NotFound)
  // Deleting what isn't there succeeds.
  assert s3.delete_object(bucket, key) == Ok(Nil)
}

pub fn listing_pages_and_prefixes_test() {
  use bucket <- with_bucket
  list.each(["a/1", "a/2", "b/1", "top"], fn(key) {
    let assert Ok(_) = s3.put_object(bucket, key, <<>>, s3.put_options())
    Nil
  })

  let assert Ok(listing) =
    s3.list_objects(
      bucket,
      s3.ListOptions(..s3.list_options(), delimiter: Some("/")),
    )
  assert list.map(listing.objects, fn(o) { o.key }) == ["top"]
  assert listing.prefixes == ["a/", "b/"]

  let assert Ok(first) =
    s3.list_objects(
      bucket,
      s3.ListOptions(..s3.list_options(), prefix: Some("a/"), max_keys: Some(1)),
    )
  assert list.map(first.objects, fn(o) { o.key }) == ["a/1"]
  let assert Some(next) = first.next
  let assert Ok(second) =
    s3.list_objects(
      bucket,
      s3.ListOptions(
        ..s3.list_options(),
        prefix: Some("a/"),
        max_keys: Some(1),
        continuation: Some(next),
      ),
    )
  assert list.map(second.objects, fn(o) { o.key }) == ["a/2"]
  assert second.next == None

  let assert Ok([]) = s3.delete_objects(bucket, ["a/1", "a/2", "missing"])
  let assert Ok(rest) = s3.list_objects(bucket, s3.list_options())
  assert list.map(rest.objects, fn(o) { o.key }) == ["b/1", "top"]
}

pub fn presigned_urls_work_test() {
  use bucket <- with_bucket
  let key = "uploads/a b.txt"

  let put_url = s3.presign_put(bucket, key, expires: duration.minutes(5))
  let assert Ok(req) = request.to(put_url)
  let assert Ok(res) =
    req
    |> request.set_method(http.Put)
    |> request.map(bit_array.from_string)
    |> request.set_body(<<"from a browser":utf8>>)
    |> httpc.send_bits
  assert res.status == 200

  let get_url = s3.presign_get(bucket, key, expires: duration.minutes(5))
  let assert Ok(req) = request.to(get_url)
  let assert Ok(res) =
    req |> request.map(bit_array.from_string) |> httpc.send_bits
  assert res.status == 200
  assert res.body == <<"from a browser":utf8>>

  // The URL is good for that key only.
  let assert Ok(req) =
    request.to(string.replace(get_url, "a%20b.txt", "other.txt"))
  let assert Ok(res) =
    req |> request.map(bit_array.from_string) |> httpc.send_bits
  assert res.status == 403
}

pub fn multipart_uploads_test() {
  use bucket <- with_bucket
  let size = s3.min_part_size + 1000
  let body = pattern(size)
  let assert Ok(_) =
    s3.put_object_in_parts(
      bucket,
      "big.bin",
      body,
      s3.put_options(),
      part_size: s3.min_part_size,
    )
  let assert Ok(object) = s3.get_object(bucket, "big.bin", range: None)
  assert bit_array.byte_size(object.body) == size
  assert object.body == body

  // An aborted upload leaves nothing behind.
  let assert Ok(upload) =
    s3.create_multipart_upload(bucket, "abandoned", s3.put_options())
  let assert Ok(_) = s3.upload_part(upload, 1, <<"part":utf8>>)
  let assert Ok(Nil) = s3.abort_multipart_upload(upload)
  assert s3.head_object(bucket, "abandoned") == Error(s3.NotFound)
}

pub fn bad_credentials_are_refused_test() {
  case envoy.get("GLOSS_TEST_S3_ENDPOINT") {
    Error(Nil) -> Nil
    Ok(endpoint) -> {
      let bucket =
        s3.new(
          access_key_id: "gloss",
          secret_access_key: "wrong",
          region: "us-east-1",
          send: httpc.send_bits,
        )
        |> s3.endpoint(endpoint)
        |> s3.bucket("anything")
      let assert Error(s3.ServerError(status: 403, ..)) =
        s3.put_object(bucket, "k", <<>>, s3.put_options())
      Nil
    }
  }
}

/// `size` bytes that aren't all the same, so misplaced parts show.
fn pattern(size: Int) -> BitArray {
  let block = <<"0123456789abcdef":utf8>>
  let blocks = size / 16
  let whole =
    list.repeat(block, blocks)
    |> bit_array.concat
  let assert Ok(tail) = bit_array.slice(block, 0, size - blocks * 16)
  bit_array.append(whole, tail)
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(Positive)) -> Int

type Positive {
  Positive
}

fn unique() -> Int {
  unique_integer([Positive])
}

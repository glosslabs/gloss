# gloss_s3

An S3 client for gloss: objects, listing, copying, presigned URLs and
multipart uploads, for AWS S3 and any service that speaks its API (MinIO,
RustFS, Cloudflare R2, Backblaze B2, DigitalOcean Spaces, ...). Requests are
signed with AWS Signature Version 4, written in-house.

```gleam
import gleam/httpc
import gleam/option.{None, Some}
import gleam/time/duration
import gloss/s3

let uploads =
  s3.new(
    access_key_id: key_id,
    secret_access_key: secret,
    region: "eu-west-2",
    send: httpc.send_bits,
  )
  |> s3.tracer(tracer)
  |> s3.bucket("forum-uploads")

let assert Ok(_etag) =
  s3.put_object(uploads, "avatars/7.png", png, s3.PutOptions(
    ..s3.put_options(),
    content_type: Some("image/png"),
  ))
let assert Ok(object) = s3.get_object(uploads, "avatars/7.png", range: None)
let link = s3.presign_get(uploads, "avatars/7.png", expires: duration.minutes(10))
```

## Operations

| Function | |
|---|---|
| `put_object(bucket, key, body, options)` | Store an object; `PutOptions` sets content type, cache control, disposition and `x-amz-meta-*` metadata. Answers the ETag |
| `get_object(bucket, key, range:)` | The object's body and `ObjectInfo`, or a byte range of it |
| `head_object(bucket, key)` | `ObjectInfo` (size, content type, ETag, last modified, metadata) without the body |
| `delete_object(bucket, key)` | Delete one object; deleting a missing one succeeds |
| `delete_objects(bucket, keys)` | Delete many, 1000 to a request; answers the keys that couldn't be deleted |
| `copy_object(from:, from_key:, to:, to_key:)` | Copy within or between buckets |
| `list_objects(bucket, options)` | A page of keys, with `prefix`, `delimiter` (shared prefixes come back as `prefixes`), `max_keys` and the `continuation` token from the previous page's `next` |
| `presign_get` / `presign_put(bucket, key, expires:)` | A URL anyone can fetch from or upload to until it expires (at most seven days) |
| `create_multipart_upload`, `upload_part`, `complete_multipart_upload`, `abort_multipart_upload` | Upload an object in parts |
| `put_object_in_parts(bucket, key, body, options, part_size:)` | One `put_object`, or a multipart upload of `part_size` parts sent in turn, aborted if a part fails |
| `create_bucket` / `delete_bucket` | Bucket setup, mostly for tests and scripts |

Errors are `Transport(reason)` (nothing came back), `NotFound` (no such key,
or a body-less 404 such as from `head_object`), `ServerError(status, code,
message)` with S3's error code (`AccessDenied`, `NoSuchBucket`, `SlowDown`,
...), and `InvalidResponse`. A copy or a completed multipart upload that S3
answers with 200 but an error in the body is reported as a `ServerError`.

## Sending

The client takes the function that performs each request, typically
`httpc.send_bits`, so the package has no HTTP client dependency and tests can
answer requests themselves. Every request is signed including the SHA-256 of
its body. Presigned URLs are signed over the host with an unsigned payload,
since the body isn't known when the URL is made.

## Buckets and endpoints

Operations act on a `Bucket` made with `s3.bucket(client, name)`: most apps
use one or two buckets, so binding the name once keeps calls short.

Without an endpoint, requests go to AWS at
`https://<bucket>.s3.<region>.amazonaws.com`. For other services set one;
requests then use path style (`<endpoint>/<bucket>/<key>`), which works for
any bucket name without DNS. `path_style(False)` switches back to
virtual-hosted style where the service supports it.

```gleam
// MinIO or RustFS running locally
s3.new(access_key_id:, secret_access_key:, region: "us-east-1", send: httpc.send_bits)
|> s3.endpoint("http://localhost:9000")

// Cloudflare R2
s3.new(access_key_id:, secret_access_key:, region: "auto", send: httpc.send_bits)
|> s3.endpoint("https://" <> account_id <> ".r2.cloudflarestorage.com")
```

Temporary credentials (an instance or task role) come with a token:
`s3.session_token(client, Some(token))`.

## Uploading from the browser

Hand the browser a presigned `PUT` URL and it can upload straight to the
bucket, without the file passing through your server:

```gleam
let url = s3.presign_put(uploads, "avatars/" <> id <> ".png", expires: duration.minutes(5))
// fetch(url, { method: "PUT", body: file })
```

## Multipart uploads

Objects over 5 GiB, or large ones you want to send in parallel or resume, go
in parts of at least 5 MiB (`s3.min_part_size`), except the last:

```gleam
let assert Ok(upload) = s3.create_multipart_upload(bucket, "video.mp4", options)
let assert Ok(one) = s3.upload_part(upload, 1, first_chunk)
let assert Ok(two) = s3.upload_part(upload, 2, last_chunk)
let assert Ok(_etag) = s3.complete_multipart_upload(upload, [one, two])
```

`put_object_in_parts` does this for a body already in memory.

## Tracing

Each request is a span from source `gloss.s3`, named after the operation
(`put_object`, `list_objects`, ...), with `bucket`, `key`, `bytes` and
`status` in its meta. A failed request marks the span failed; a missing
object doesn't. Spans are children of the calling process's current span, so
S3 calls made while handling a request appear in its trace.

## Testing

The signing tests use the examples from the AWS Signature Version 4
documentation. The integration tests run against a real S3-compatible server
when `GLOSS_TEST_S3_ENDPOINT` is set:

```sh
docker run -d --name gloss-s3-test -p 9010:9000 \
  -e RUSTFS_ACCESS_KEY=gloss -e RUSTFS_SECRET_KEY=glosssecret rustfs/rustfs
GLOSS_TEST_S3_ENDPOINT=http://localhost:9010 gleam test
```

`GLOSS_TEST_S3_ACCESS_KEY`, `GLOSS_TEST_S3_SECRET_KEY` and `GLOSS_TEST_S3_REGION` default to
`gloss`, `glosssecret` and `us-east-1`.

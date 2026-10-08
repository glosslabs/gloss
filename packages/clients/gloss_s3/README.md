# gloss_s3

An S3 client with in-house SigV4 signing, for AWS, Cloudflare R2 and other
S3-compatible stores. Imported as `gloss/s3`; it takes the function that
sends HTTP requests, such as `httpc.send_bits`.

```gleam
let client =
  s3.new(access_key_id:, secret_access_key:, region: "auto", send: httpc.send_bits)
  |> s3.endpoint("https://<account>.r2.cloudflarestorage.com")
let uploads = s3.bucket(client, "uploads")

let assert Ok(_) = s3.put_object(uploads, "a.txt", <<"hi":utf8>>, s3.put_options())
s3.presign_get(uploads, "a.txt", expires: duration.minutes(10))
```

- Objects (put, get with ranges, head, delete, copy), listing, presigned URLs and multipart uploads.
- Its live tests run when `GLOSS_TEST_S3_ENDPOINT` is set.

# gloss_url

Building and reading URLs and query strings, on the BEAM and in JavaScript.
Imported as `gloss/url`; it builds on `gleam/uri`.

```gleam
let assert Ok(api) = url.parse("https://api.example.com/v1")
api
|> url.segments(["users", "42", "posts"])
|> url.query("tag", "a&b")
|> url.to_string
// -> "https://api.example.com/v1/users/42/posts?tag=a%26b"
```

- Path segments and query parameters are encoded for you; `set_query` and `delete_query` edit them.
- `username`, `password`, `path_segments` and `params` read connection URLs, decoded.
- `encode` is strict RFC 3986, as S3 and OAuth signatures need.

# gloss_url

Building and reading URLs and query strings, on the BEAM and in JavaScript.
Imported as `gloss/url`, it sits on `gleam/uri` and adds what building URLs
needs: path segments and query parameters encoded for you, strict RFC 3986
encoding, and the user, password and parameters of connection URLs, decoded.

```gleam
import gloss/url

let assert Ok(api) = url.parse("https://api.example.com/v1")
api
|> url.segments(["users", user_id, "posts"])
|> url.query("tag", "a&b")
|> url.to_string
// -> "https://api.example.com/v1/users/42/posts?tag=a%26b"

let assert Ok(db) = url.parse("postgres://ada:p%40ss@db:5432/app?sslmode=require")
url.password(db)       // -> Some("p@ss")
url.path_segments(db)  // -> ["app"]
url.params(db)         // -> [#("sslmode", "require")]
```

| | |
|---|---|
| Building | `segment`, `segments`, `query`, `set_query`, `delete_query`, `set_fragment`, `to_string`, `to_uri` |
| Reading | `parse`, `from_uri`, `scheme`, `host`, `port`, `path`, `path_segments`, `params`, `param`, `username`, `password`, `fragment` |
| Encoding | `encode` (strict: all but `A-Z a-z 0-9 - _ . ~`), `decode`, `query_string`, `parse_query` |

import gleam/option.{None, Some}
import gloss/url

pub fn builds_urls_with_encoded_parts_test() {
  let assert Ok(api) = url.parse("https://api.example.com/v1")
  assert api
    |> url.segments(["users", "a/b c", "posts"])
    |> url.query("tag", "a&b=c")
    |> url.query("tag", "é")
    |> url.set_fragment(Some("top"))
    |> url.to_string
    == "https://api.example.com/v1/users/a%2Fb%20c/posts?tag=a%26b%3Dc&tag=%C3%A9#top"
  // A trailing slash isn't doubled.
  let assert Ok(root) = url.parse("http://localhost:4318/")
  assert root |> url.segments(["v1", "traces"]) |> url.to_string
    == "http://localhost:4318/v1/traces"
}

pub fn existing_queries_are_kept_and_edited_test() {
  let assert Ok(page) = url.parse("/search?q=gleam+lang&page=1&page=2")
  assert url.params(page)
    == [#("q", "gleam lang"), #("page", "1"), #("page", "2")]
  assert url.param(page, "page") == Ok("1")
  assert page |> url.set_query("page", "3") |> url.to_string
    == "/search?q=gleam%20lang&page=3"
  assert page
    |> url.delete_query("page")
    |> url.delete_query("q")
    |> url.to_string
    == "/search"
  let assert Error(Nil) = url.parse("/x?a=%zz")
}

pub fn connection_urls_are_read_decoded_test() {
  let assert Ok(db) =
    url.parse(
      "postgres://ada:p%40ss%3Aw@db.internal:5433/my%20app?sslmode=require",
    )
  assert url.scheme(db) == Some("postgres")
  assert url.host(db) == Some("db.internal")
  assert url.port(db) == Some(5433)
  assert url.username(db) == Some("ada")
  assert url.password(db) == Some("p@ss:w")
  assert url.path_segments(db) == ["my app"]
  assert url.params(db) == [#("sslmode", "require")]

  let assert Ok(redis) = url.parse("redis://:secret@localhost/2")
  assert url.username(redis) == None
  assert url.password(redis) == Some("secret")
  let assert Ok(bare) = url.parse("mysql://root@localhost")
  assert url.username(bare) == Some("root")
  assert url.password(bare) == None
  assert url.path_segments(bare) == []
  assert url.fragment(bare) == None
}

pub fn encoding_is_strict_rfc3986_test() {
  assert url.encode("AZaz09-_.~") == "AZaz09-_.~"
  assert url.encode("a b/?#[]@!$&'()*+,;=:é")
    == "a%20b%2F%3F%23%5B%5D%40%21%24%26%27%28%29%2A%2B%2C%3B%3D%3A%C3%A9"
  assert url.decode("a%20b%2F%C3%A9") == Ok("a b/é")
  assert url.query_string([#("q", "gleam lang"), #("n", "1+1")])
    == "q=gleam%20lang&n=1%2B1"
  assert url.parse_query("a=1&b=x+y") == Ok([#("a", "1"), #("b", "x y")])
}

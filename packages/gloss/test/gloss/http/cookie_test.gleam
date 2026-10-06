import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import gleeunit/should
import gloss/http/cookie
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import http_support.{request}

pub fn get_test() {
  let req =
    request(http.Get, "/")
    |> request.set_header("cookie", "theme=dark; lang=en")
  cookie.get(req, "lang") |> should.equal(Ok("en"))
  cookie.get(req, "missing") |> should.equal(Error(Nil))
  cookie.all(req) |> should.equal([#("theme", "dark"), #("lang", "en")])
}

pub fn malformed_cookies_are_ignored_test() {
  let req =
    request(http.Get, "/")
    |> request.set_header("cookie", "bad value=1; ok=2")
  cookie.all(req) |> should.equal([#("ok", "2")])
}

pub fn set_uses_secure_defaults_test() {
  let res = reply.empty(204) |> cookie.set("theme", "dark", cookie.defaults())
  response.get_header(res, "set-cookie")
  |> should.equal(Ok("theme=dark; Path=/; Secure; HttpOnly; SameSite=Lax"))
}

pub fn max_age_test() {
  let res =
    reply.empty(204)
    |> cookie.set("t", "1", cookie.defaults() |> cookie.max_age(3600))
  response.get_header(res, "set-cookie")
  |> should.equal(Ok(
    "t=1; Max-Age=3600; Path=/; Secure; HttpOnly; SameSite=Lax",
  ))
}

pub fn delete_expires_the_cookie_test() {
  let res = reply.empty(204) |> cookie.delete("theme", cookie.defaults())
  let assert Ok(header) = response.get_header(res, "set-cookie")
  header
  |> should.equal(
    "theme=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Lax",
  )
}

pub fn several_cookies_survive_the_server_test() {
  let routes =
    router.new()
    |> router.get("/", fn(_, _) {
      reply.empty(204)
      |> cookie.set("a", "1", cookie.defaults())
      |> cookie.set("b", "2", cookie.defaults())
    })
  let res = server.handle(server.new(routes, Nil), request(http.Get, "/"))
  res.headers
  |> list.filter_map(fn(header) {
    case header {
      #("set-cookie", value) -> Ok(value)
      _ -> Error(Nil)
    }
  })
  |> list.map(string.slice(_, 0, 3))
  |> should.equal(["b=2", "a=1"])
}

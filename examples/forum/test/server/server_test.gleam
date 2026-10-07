//// The server, through server.handle: requests carry the session cookie
//// a previous response set, like a browser.

import app/config.{Config}
import domain/accounts
import domain/forum
import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import gloss/http/body
import gloss/http/reply
import gloss/http/server as gloss_server
import gloss/logger
import gloss/tracer
import server
import server/state
import support/memory_threads
import support/memory_users

type Browser {
  Browser(send: fn(reply.Request) -> Response(bytes_tree.BytesTree))
}

fn browser() -> #(Browser, String) {
  let data_dir =
    "build/test-data/"
    <> int.to_string(system_time())
    <> "-"
    <> int.to_string(unique())
  let config =
    Config(..config.defaults(), port: 0, environment: "test", data_dir:)
  let state =
    state.new(
      accounts: accounts.new(memory_users.start()),
      forum: forum.new(memory_threads.start()),
      avatars_dir: data_dir <> "/avatars",
    )
  let builder =
    server.builder(
      config,
      state,
      logger: logger.discard(),
      tracer: tracer.new(),
    )
  #(Browser(send: fn(req) { gloss_server.handle(builder, req) }), data_dir)
}

fn get(path: String, cookie: String) {
  request.new()
  |> request.set_method(http.Get)
  |> request.set_scheme(http.Http)
  |> request.set_path(path)
  |> request.set_header("cookie", "forum_session=" <> cookie)
  |> request.set_header("accept", "text/html")
  |> request.set_body(body.from_bits(<<>>))
}

fn post_form(path: String, cookie: String, fields: List(#(String, String))) {
  get(path, cookie)
  |> request.set_method(http.Post)
  |> request.set_header("content-type", "application/x-www-form-urlencoded")
  |> request.set_body(body.from_string(uri_encode(fields)))
}

fn uri_encode(fields: List(#(String, String))) -> String {
  fields
  |> list.map(fn(field) { field.0 <> "=" <> string.replace(field.1, " ", "+") })
  |> string.join("&")
}

fn session_cookie(res: Response(a)) -> String {
  res.headers
  |> list.find_map(fn(header) {
    case header {
      #("set-cookie", "forum_session=" <> rest) ->
        case string.split_once(rest, ";") {
          Ok(#(value, _)) -> Ok(value)
          Error(Nil) -> Ok(rest)
        }
      _ -> Error(Nil)
    }
  })
  |> unwrap("")
}

fn unwrap(result: Result(a, b), default: a) -> a {
  case result {
    Ok(value) -> value
    Error(_) -> default
  }
}

fn text(res: Response(bytes_tree.BytesTree)) -> String {
  let assert Ok(text) = bit_array.to_string(bytes_tree.to_bit_array(res.body))
  text
}

fn location(res: Response(a)) -> String {
  response.get_header(res, "location") |> unwrap("")
}

/// Register a user and return their session cookie.
fn register(browser: Browser, email: String) -> String {
  let res =
    browser.send(
      post_form("/register", "", [
        #("email", email),
        #("password", "correct horse"),
      ]),
    )
  res.status |> should.equal(303)
  session_cookie(res)
}

pub fn registration_test() {
  let #(browser, _) = browser()
  let cookie = register(browser, "ada@example.com")
  { cookie != "" } |> should.be_true
  browser.send(get("/", cookie))
  |> text
  |> string.contains("Sign out")
  |> should.be_true

  let res =
    browser.send(
      post_form("/register", "", [
        #("email", "ada@example.com"),
        #("password", "correct horse"),
      ]),
    )
  res.status |> should.equal(422)
  text(res) |> string.contains("already registered") |> should.be_true
}

pub fn login_and_logout_test() {
  let #(browser, _) = browser()
  let _ = register(browser, "ada@example.com")
  let wrong =
    browser.send(
      post_form("/login", "", [
        #("email", "ada@example.com"),
        #("password", "nope nope"),
      ]),
    )
  wrong.status |> should.equal(422)

  let res =
    browser.send(
      post_form("/login", "", [
        #("email", "ada@example.com"),
        #("password", "correct horse"),
      ]),
    )
  res.status |> should.equal(303)
  let cookie = session_cookie(res)
  browser.send(post_form("/logout", cookie, [])).status |> should.equal(303)
  // The old session no longer signs anyone in.
  browser.send(get("/threads/new", cookie))
  |> location
  |> should.equal("/login")
}

pub fn threads_and_replies_test() {
  let #(browser, _) = browser()
  browser.send(get("/threads/new", "")) |> location |> should.equal("/login")
  let cookie = register(browser, "ada@example.com")

  let res =
    browser.send(
      post_form("/threads", cookie, [
        #("title", "Hello there"),
        #("body", "First post"),
      ]),
    )
  location(res) |> should.equal("/threads/1")
  browser.send(post_form("/threads", cookie, [#("title", ""), #("body", "x")])).status
  |> should.equal(422)

  let bob = register(browser, "bob@example.com")
  browser.send(post_form("/threads/1/replies", bob, [#("body", "A reply")]))
  |> location
  |> should.equal("/threads/1#post-2")

  let page = browser.send(get("/threads/1", "")) |> text
  string.contains(page, "First post") |> should.be_true
  string.contains(page, "A reply") |> should.be_true
  string.contains(page, "bob") |> should.be_true

  browser.send(get("/", ""))
  |> text
  |> string.contains("1 reply")
  |> should.be_true
  browser.send(get("/threads/99", "")).status |> should.equal(404)
}

pub fn profile_and_avatar_test() {
  let #(browser, _) = browser()
  let cookie = register(browser, "ada@example.com")
  browser.send(
    post_form("/profile", cookie, [
      #("display_name", "Ada L"),
      #("bio", "Counts things"),
    ]),
  ).status
  |> should.equal(303)
  browser.send(get("/users/1", ""))
  |> text
  |> string.contains("Ada L")
  |> should.be_true

  let upload = fn(content_type, data: BitArray) {
    let payload = <<
      "--B\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"a\"\r\nContent-Type: ":utf8,
      content_type:utf8,
      "\r\n\r\n":utf8,
      data:bits,
      "\r\n--B--\r\n":utf8,
    >>
    browser.send(
      get("/profile/avatar", cookie)
      |> request.set_method(http.Post)
      |> request.set_header("content-type", "multipart/form-data; boundary=B")
      |> request.set_body(body.from_bits(payload)),
    )
  }
  upload("image/png", <<"png bytes":utf8>>)
  |> location
  |> should.equal("/profile")
  upload("text/plain", <<"x":utf8>>).status |> should.equal(415)
  upload("image/png", <<0:size(16_000_008)>>).status |> should.equal(413)

  let assert [path] =
    browser.send(get("/profile", cookie))
    |> text
    |> string.split("src=\"")
    |> list.drop(1)
    |> list.map(fn(rest) {
      rest |> string.split("\"") |> list.first |> unwrap("")
    })
    |> list.filter(string.starts_with(_, "/avatars/"))
  let avatar = browser.send(get(path, ""))
  avatar.status |> should.equal(200)
  text(avatar) |> should.equal("png bytes")
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueOption)) -> Int

type UniqueOption {
  Positive
}

fn unique() -> Int {
  unique_integer([Positive])
}

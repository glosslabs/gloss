//// The server, through server.handle, driven by gloss_test browsers that
//// keep their own session cookies. Each person in a test gets a browser;
//// they share one application.

import app/config.{Config}
import domain/accounts
import domain/forum
import gleam/int
import gleam/list
import gleam/string
import gloss/http/reply.{type Request}
import gloss/http/server as gloss_server
import gloss/logger
import gloss/testing/browser.{type Browser}
import gloss/testing/html
import gloss/testing/request
import gloss/testing/response
import gloss/tracer
import server
import server/state
import support/memory_threads
import support/memory_users

/// A fresh application with in-memory stores, as a function a browser can
/// send requests to.
fn app() -> fn(Request) -> response.Response {
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
  gloss_server.handle(builder, _)
}

/// The visible text of the page at `path`.
fn page(b: Browser, path: String) -> String {
  browser.get(b, path) |> response.text |> html.text
}

/// Register an account in `b`, which is then signed in.
fn register(b: Browser, email: String) -> Nil {
  let res =
    browser.submit(b, "/register", [
      #("email", email),
      #("password", "correct horse"),
    ])
  assert res.status == 303
  assert browser.cookie(b, "forum_session") |> result_is_ok
}

pub fn registration_test() {
  let ada = browser.new(app())
  register(ada, "ada@example.com")
  assert string.contains(page(ada, "/"), "Sign out")

  let app = app()
  register(browser.new(app), "ada@example.com")
  let taken =
    browser.submit(browser.new(app), "/register", [
      #("email", "ada@example.com"),
      #("password", "correct horse"),
    ])
  assert taken.status == 422
  assert string.contains(html.text(response.text(taken)), "already registered")
}

pub fn login_and_logout_test() {
  let app = app()
  register(browser.new(app), "ada@example.com")
  let ada = browser.new(app)

  let wrong =
    browser.submit(ada, "/login", [
      #("email", "ada@example.com"),
      #("password", "nope nope"),
    ])
  assert wrong.status == 422

  let res =
    browser.submit(ada, "/login", [
      #("email", "ada@example.com"),
      #("password", "correct horse"),
    ])
  assert res.status == 303
  let assert Ok(session) = browser.cookie(ada, "forum_session")

  assert browser.submit(ada, "/logout", []).status == 303
  // The old session no longer signs anyone in, even if a client keeps it.
  let replay = browser.new(app)
  let old =
    browser.send(
      replay,
      request.get("/threads/new") |> request.cookie("forum_session", session),
    )
  assert response.location(old) == Ok("/login")
}

pub fn threads_and_replies_test() {
  let app = app()
  let visitor = browser.new(app)
  assert response.location(browser.get(visitor, "/threads/new")) == Ok("/login")

  let ada = browser.new(app)
  register(ada, "ada@example.com")
  let opened =
    browser.submit(ada, "/threads", [
      #("title", "Hello there"),
      #("body", "First post"),
    ])
  assert response.location(opened) == Ok("/threads/1")
  assert browser.submit(ada, "/threads", [#("title", ""), #("body", "x")]).status
    == 422

  let bob = browser.new(app)
  register(bob, "bob@example.com")
  let replied =
    browser.submit(bob, "/threads/1/replies", [#("body", "A reply")])
  assert response.location(replied) == Ok("/threads/1#post-2")

  let thread = page(visitor, "/threads/1")
  assert string.contains(thread, "First post")
  assert string.contains(thread, "A reply")
  assert string.contains(thread, "bob")
  assert string.contains(page(visitor, "/"), "1 reply")
  assert browser.get(visitor, "/threads/99").status == 404
}

pub fn profile_and_avatar_test() {
  let app = app()
  let ada = browser.new(app)
  register(ada, "ada@example.com")
  let saved =
    browser.submit(ada, "/profile", [
      #("display_name", "Ada L"),
      #("bio", "Counts things"),
    ])
  assert saved.status == 303
  assert string.contains(page(browser.new(app), "/users/1"), "Ada L")

  let upload = fn(content_type, data: BitArray) {
    browser.send(
      ada,
      request.post("/profile/avatar")
        |> request.multipart([request.File("avatar", "a", content_type, data)]),
    )
  }
  assert response.location(upload("image/png", <<"png bytes":utf8>>))
    == Ok("/profile")
  assert upload("text/plain", <<"x":utf8>>).status == 415
  assert upload("image/png", <<0:size(16_000_008)>>).status == 413

  let assert [path] =
    browser.get(ada, "/profile")
    |> response.text
    |> html.attribute_values("src")
    |> list.filter(string.starts_with(_, "/avatars/"))
  let avatar = browser.get(ada, path)
  assert avatar.status == 200
  assert response.text(avatar) == "png bytes"
}

fn result_is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
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

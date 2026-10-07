import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import gloss/clock
import gloss/http/context
import gloss/http/cookie
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import gloss/http/session.{type Sessions}
import gloss/http/session/memory
import http_support.{header, rendered_body, request}

fn sessions() -> Sessions {
  let assert Ok(store) = memory.start()
  session.new(store)
}

/// Routes that read, write, regenerate and destroy a session.
fn app(sessions: Sessions) {
  let routes =
    router.new()
    |> router.get("/read", fn(req, ctx) {
      use s <- session.load(req, ctx.sessions)
      case session.get(s, "user") {
        Ok(user) -> reply.text(200, user)
        Error(Nil) -> reply.text(200, "anonymous")
      }
    })
    |> router.post("/login/:user", fn(req, ctx) {
      use s <- session.load(req, ctx.sessions)
      let assert Ok(user) = context.param(ctx, "user")
      s
      |> session.regenerate
      |> session.set("user", user)
      |> session.save(reply.empty(204))
    })
    |> router.post("/logout", fn(req, ctx) {
      use s <- session.load(req, ctx.sessions)
      session.destroy(s, reply.empty(204))
    })
  let builder = server.new(routes, Nil) |> server.sessions(sessions)
  fn(req) { server.handle(builder, req) }
}

/// The session id from a response's set-cookie, if any.
fn session_cookie(res: response.Response(a)) -> Result(String, Nil) {
  res.headers
  |> list.find_map(fn(header) {
    case header {
      #("set-cookie", "session=" <> rest) ->
        case string.split_once(rest, ";") {
          Ok(#(id, _)) -> Ok(id)
          Error(Nil) -> Ok(rest)
        }
      _ -> Error(Nil)
    }
  })
}

fn with_session(req, id: String) {
  request.set_header(req, "cookie", "session=" <> id)
}

pub fn reading_does_not_create_a_session_test() {
  let send = app(sessions())
  let res = send(request(http.Get, "/read"))
  rendered_body(res) |> should.equal("anonymous")
  session_cookie(res) |> should.equal(Error(Nil))
}

pub fn saved_session_round_trips_test() {
  let send = app(sessions())
  let res = send(request(http.Post, "/login/ada"))
  let assert Ok(id) = session_cookie(res)
  string.length(id) |> should.equal(43)
  string.contains(header(res, "set-cookie"), "Max-Age=1209600")
  |> should.be_true

  send(request(http.Get, "/read") |> with_session(id))
  |> rendered_body
  |> should.equal("ada")
}

pub fn unknown_ids_get_a_fresh_session_test() {
  let send = app(sessions())
  send(request(http.Get, "/read") |> with_session("forged"))
  |> rendered_body
  |> should.equal("anonymous")
}

pub fn regenerate_retires_the_old_id_test() {
  let send = app(sessions())
  let assert Ok(first) = session_cookie(send(request(http.Post, "/login/ada")))
  let assert Ok(second) =
    session_cookie(send(request(http.Post, "/login/bob") |> with_session(first)))
  should.not_equal(first, second)

  send(request(http.Get, "/read") |> with_session(first))
  |> rendered_body
  |> should.equal("anonymous")
  send(request(http.Get, "/read") |> with_session(second))
  |> rendered_body
  |> should.equal("bob")
}

pub fn destroy_removes_the_session_and_cookie_test() {
  let send = app(sessions())
  let assert Ok(id) = session_cookie(send(request(http.Post, "/login/ada")))
  let res = send(request(http.Post, "/logout") |> with_session(id))
  session_cookie(res) |> should.equal(Ok(""))
  string.contains(header(res, "set-cookie"), "Max-Age=0") |> should.be_true

  send(request(http.Get, "/read") |> with_session(id))
  |> rendered_body
  |> should.equal("anonymous")
}

pub fn expired_sessions_are_not_loaded_test() {
  let assert Ok(store) = memory.start()
  let at = fn(seconds) {
    session.new(store)
    |> session.ttl(duration.minutes(30))
    |> session.clock(clock.fixed(timestamp.from_unix_seconds(seconds)))
    |> app
  }
  let assert Ok(id) = session_cookie(at(0)(request(http.Post, "/login/ada")))

  at(1799)(request(http.Get, "/read") |> with_session(id))
  |> rendered_body
  |> should.equal("ada")
  at(1800)(request(http.Get, "/read") |> with_session(id))
  |> rendered_body
  |> should.equal("anonymous")
}

pub fn custom_cookie_name_and_attributes_test() {
  let sessions =
    sessions()
    |> session.cookie_name("sid")
    |> session.cookie_attributes(cookie.defaults() |> cookie.secure(False))
  let res = app(sessions)(request(http.Post, "/login/ada"))
  let set_cookie = header(res, "set-cookie")
  string.starts_with(set_cookie, "sid=") |> should.be_true
  string.contains(set_cookie, "Secure") |> should.be_false
}

pub fn unconfigured_sessions_fail_to_save_test() {
  let routes =
    router.new()
    |> router.post("/", fn(req, ctx) {
      use s <- session.load(req, ctx.sessions)
      session.save(session.set(s, "k", "v"), reply.empty(204))
    })
  let res = server.handle(server.new(routes, Nil), request(http.Post, "/"))
  res.status |> should.equal(500)
}

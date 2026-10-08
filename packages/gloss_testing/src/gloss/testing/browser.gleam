//// A browser over `server.handle`: it keeps the cookies responses set and
//// sends them back, so a test reads as a sequence of page visits.
////
//// ```gleam
//// let b = browser.new(server.handle(builder, _))
//// let res = browser.submit(b, "/login", [#("email", "ada@x"), #("password", "pw")])
//// assert response.location(res) == Ok("/")
//// assert string.contains(response.text(browser.get(b, "/")), "Sign out")
//// ```
////
//// Like a browser, it asks for HTML (`accept: text/html`) and says each
//// request comes from this site (`sec-fetch-site: same-origin`), unless a
//// request sets those headers itself. Cookies are kept per name, honour
//// `Path`, and are removed by `Max-Age=0` or an empty value.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import gloss/http/reply.{type Request}
import gloss/testing/request as req
import gloss/testing/response.{type Response}

pub opaque type Browser {
  Browser(handle: fn(Request) -> Response, jar: Subject(Message))
}

type Cookie {
  Cookie(value: String, path: String)
}

type Message {
  Store(List(#(String, String, List(#(String, String)))))
  Matching(path: String, reply: Subject(List(#(String, String))))
  Get(name: String, reply: Subject(Result(String, Nil)))
  Clear
}

/// A browser with no cookies, sending requests to `handle`, typically
/// `server.handle(builder, _)`.
pub fn new(handle: fn(Request) -> Response) -> Browser {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(on_message)
    |> actor.start
  Browser(handle:, jar: started.data)
}

/// Send `request` with the browser's cookies and headers, and keep the
/// cookies the response sets.
pub fn send(browser: Browser, request: Request) -> Response {
  let cookies = process.call(browser.jar, 1000, Matching(request.path, _))
  let request =
    list.fold(cookies, request, fn(r, cookie) {
      req.cookie(r, cookie.0, cookie.1)
    })
    |> default_header("accept", "text/html")
    |> default_header("sec-fetch-site", "same-origin")
  let res = browser.handle(request)
  process.send(browser.jar, Store(response.set_cookies(res)))
  res
}

pub fn get(browser: Browser, path: String) -> Response {
  send(browser, req.get(path))
}

/// Submit a form: a URL-encoded `POST` to `path`.
pub fn submit(
  browser: Browser,
  path: String,
  fields: List(#(String, String)),
) -> Response {
  send(browser, req.post(path) |> req.form(fields))
}

/// Follow a redirect with a `GET` to its `location`, as a browser does
/// after a form post. Any other response is returned as it is.
pub fn follow(browser: Browser, res: Response) -> Response {
  case res.status >= 300 && res.status < 400, response.location(res) {
    True, Ok(location) -> get(browser, location)
    _, _ -> res
  }
}

/// The value of a cookie the browser holds.
pub fn cookie(browser: Browser, name: String) -> Result(String, Nil) {
  process.call(browser.jar, 1000, Get(name, _))
}

/// Forget every cookie, as if the browser were closed.
pub fn clear_cookies(browser: Browser) -> Nil {
  process.send(browser.jar, Clear)
}

fn default_header(request: Request, name: String, value: String) -> Request {
  case request.get_header(request, name) {
    Ok(_) -> request
    Error(Nil) -> req.header(request, name, value)
  }
}

fn on_message(
  jar: Dict(String, Cookie),
  message: Message,
) -> actor.Next(Dict(String, Cookie), Message) {
  case message {
    Store(cookies) ->
      list.fold(cookies, jar, fn(jar, cookie) {
        let #(name, value, attributes) = cookie
        let expired =
          value == ""
          || list.key_find(attributes, "max-age")
          |> result.map(fn(age) {
            string.starts_with(age, "0") || string.starts_with(age, "-")
          })
          |> result.unwrap(False)
        case expired {
          True -> dict.delete(jar, name)
          False ->
            dict.insert(
              jar,
              name,
              Cookie(
                value:,
                path: list.key_find(attributes, "path") |> result.unwrap("/"),
              ),
            )
        }
      })
      |> actor.continue
    Matching(path:, reply:) -> {
      dict.to_list(jar)
      |> list.filter(fn(entry) { string.starts_with(path, { entry.1 }.path) })
      |> list.map(fn(entry) { #(entry.0, { entry.1 }.value) })
      |> process.send(reply, _)
      actor.continue(jar)
    }
    Get(name:, reply:) -> {
      process.send(reply, dict.get(jar, name) |> result.map(fn(c) { c.value }))
      actor.continue(jar)
    }
    Clear -> actor.continue(dict.new())
  }
}

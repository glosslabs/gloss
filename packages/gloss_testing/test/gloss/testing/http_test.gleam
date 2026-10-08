import gleam/dynamic/decode
import gleam/http/request as http_request
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import gloss/http/body
import gloss/http/cookie
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import gloss/testing/browser
import gloss/testing/html
import gloss/testing/request
import gloss/testing/response

/// A small app: echoes forms and JSON, sets and clears a cookie, and
/// renders a page.
fn app() {
  let routes =
    router.new()
    |> router.post("/form", fn(req, _) {
      use form <- body.form(req)
      let files =
        list.map(form.files, fn(file) { file.0 <> ":" <> { file.1 }.filename })
      reply.text(
        200,
        string.inspect(form.values) <> " " <> string.join(files, ","),
      )
    })
    |> router.post("/json", fn(req, _) {
      use name <- body.json(req, decode.at(["name"], decode.string))
      reply.json(200, json.object([#("hello", json.string(name))]))
    })
    |> router.get("/query", fn(req, _) {
      reply.text(200, option.unwrap(req.query, ""))
    })
    |> router.post("/login", fn(_, _) {
      reply.redirect("/me")
      |> cookie.set("session", "abc", cookie.defaults())
    })
    |> router.post("/logout", fn(_, _) {
      reply.redirect("/me") |> cookie.delete("session", cookie.defaults())
    })
    |> router.get("/me", fn(req, _) {
      case cookie.get(req, "session") {
        Ok(session) -> reply.text(200, "signed in as " <> session)
        Error(Nil) -> reply.text(200, "anonymous")
      }
    })
    |> router.get("/page", fn(_, _) {
      reply.html(
        200,
        "<html><head><style>p{}</style></head><body><h1>Hi &amp; welcome</h1>"
          <> "<img src=\"/a.png\" alt=\"A\"><script>var x = 1;</script>"
          <> "<a href=\"/one\">One</a>\n  <a href=\"/two?x=1&amp;y=2\">Two</a></body></html>",
      )
    })
  server.new(routes, Nil)
}

pub fn forms_are_url_encoded_test() {
  let res =
    request.post("/form")
    |> request.form([#("name", "Ada Lovelace"), #("note", "a&b=c")])
    |> server.handle(app(), _)
  assert response.text(res)
    == "[#(\"name\", \"Ada Lovelace\"), #(\"note\", \"a&b=c\")] "
}

pub fn multipart_forms_carry_files_test() {
  let res =
    request.post("/form")
    |> request.multipart([
      request.Field("title", "Hello"),
      request.File("avatar", "a.png", "image/png", <<1, 2, 3>>),
    ])
    |> server.handle(app(), _)
  assert response.text(res) == "[#(\"title\", \"Hello\")] avatar:a.png"
}

pub fn json_in_and_out_test() {
  let res =
    request.post("/json")
    |> request.json(json.object([#("name", json.string("Ada"))]))
    |> server.handle(app(), _)
  assert res.status == 200
  assert response.json(res, decode.at(["hello"], decode.string)) == Ok("Ada")
  assert response.header(res, "Content-Type") == Ok("application/json")
}

pub fn a_path_may_carry_a_query_test() {
  let res = server.handle(app(), request.get("/query?page=2&q=x"))
  assert response.text(res) == "page=2&q=x"
}

pub fn set_cookies_are_read_test() {
  let res = server.handle(app(), request.post("/login"))
  assert response.cookie(res, "session") == Ok("abc")
  assert response.location(res) == Ok("/me")
  let assert [#("session", "abc", attributes)] = response.set_cookies(res)
  assert list.key_find(attributes, "path") == Ok("/")
}

pub fn the_browser_keeps_and_drops_cookies_test() {
  let b = browser.new(server.handle(app(), _))
  assert response.text(browser.get(b, "/me")) == "anonymous"
  let res = browser.submit(b, "/login", [])
  assert browser.cookie(b, "session") == Ok("abc")
  assert response.text(browser.follow(b, res)) == "signed in as abc"
  let _ = browser.submit(b, "/logout", [])
  assert browser.cookie(b, "session") == Error(Nil)
  assert response.text(browser.get(b, "/me")) == "anonymous"
}

pub fn the_browser_asks_for_html_test() {
  let b = browser.new(server.handle(app(), _))
  let missing = browser.get(b, "/nowhere")
  assert missing.status == 404
  assert response.header(missing, "content-type")
    |> option_contains("text/html")
  // A request may still ask for something else.
  let as_json =
    browser.send(
      b,
      request.get("/nowhere") |> request.header("accept", "application/json"),
    )
  assert response.header(as_json, "content-type") |> option_contains("json")
}

pub fn html_text_is_what_a_reader_sees_test() {
  let page = response.text(server.handle(app(), request.get("/page")))
  assert html.text(page) == "Hi & welcome One Two"
  assert html.attribute_values(page, "href") == ["/one", "/two?x=1&y=2"]
  assert html.attribute_values(page, "src") == ["/a.png"]
  assert html.attribute_values(page, "title") == []
}

pub fn headers_and_cookies_are_added_to_requests_test() {
  let req =
    request.get("/")
    |> request.header("X-Thing", "1")
    |> request.cookie("a", "1")
    |> request.cookie("b", "2")
  assert http_request.get_header(req, "x-thing") == Ok("1")
  assert http_request.get_header(req, "cookie") == Ok("a=1; b=2")
}

fn option_contains(header: Result(String, Nil), text: String) -> Bool {
  case header {
    Ok(value) -> string.contains(value, text)
    Error(Nil) -> False
  }
}

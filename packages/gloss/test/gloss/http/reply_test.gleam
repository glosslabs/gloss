import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/string
import gleeunit/should
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import http_support.{header, rendered_body, request}

fn render(res: reply.Response, accept: String) {
  http_support.render(res, Ok(accept))
}

pub fn problem_as_json_test() {
  let res = render(reply.unprocessable(["title: required"]), "application/json")
  header(res, "content-type") |> should.equal("application/json")
  header(res, "vary") |> should.equal("accept")
  rendered_body(res)
  |> should.equal(
    "{\"error\":\"unprocessable content\",\"errors\":[\"title: required\"]}",
  )
}

pub fn problem_details_are_omitted_when_empty_test() {
  render(reply.not_found(), "application/json")
  |> rendered_body
  |> should.equal("{\"error\":\"not found\"}")
}

pub fn problem_as_problem_json_test() {
  let res = render(reply.not_found(), "application/problem+json")
  header(res, "content-type") |> should.equal("application/problem+json")
  rendered_body(res)
  |> should.equal(
    "{\"type\":\"about:blank\",\"title\":\"Not Found\",\"status\":404,\"detail\":\"not found\"}",
  )
}

pub fn problem_as_text_test() {
  let res = render(reply.problem(422, "invalid", ["a", "b"]), "text/plain")
  header(res, "content-type") |> should.equal("text/plain; charset=utf-8")
  rendered_body(res) |> should.equal("invalid\na\nb")
}

pub fn problem_as_html_is_escaped_test() {
  let res = render(reply.bad_request("<script>"), "text/html")
  header(res, "content-type") |> should.equal("text/html; charset=utf-8")
  let html = rendered_body(res)
  string.contains(html, "<h1>Bad Request</h1>") |> should.be_true
  string.contains(html, "&lt;script&gt;") |> should.be_true
  string.contains(html, "<script>") |> should.be_false
}

pub fn unacceptable_falls_back_to_json_test() {
  render(reply.not_found(), "image/png")
  |> header("content-type")
  |> should.equal("application/json")
}

pub fn non_problem_bodies_are_not_negotiated_test() {
  let res = render(reply.text(200, "hi"), "application/json")
  header(res, "content-type") |> should.equal("text/plain; charset=utf-8")
  header(res, "vary") |> should.equal("")
  rendered_body(res) |> should.equal("hi")
}

pub fn preferred_test() {
  let req =
    request(http.Get, "/")
    |> request.set_header("accept", "text/html;q=0.9, application/json")
  reply.preferred(req, ["text/html", "application/json"])
  |> should.equal(Ok("application/json"))
  reply.preferred(request(http.Get, "/"), ["text/html", "application/json"])
  |> should.equal(Ok("text/html"))
}

pub fn server_uses_the_custom_error_page_test() {
  let builder =
    server.new(router.new(), Nil)
    |> server.error_page(fn(page) {
      "<p>" <> page.title <> ": " <> page.message <> "</p>"
    })
  let res =
    server.handle(
      builder,
      request(http.Get, "/missing") |> request.set_header("accept", "text/html"),
    )
  res.status |> should.equal(404)
  rendered_body(res) |> should.equal("<p>Not Found: not found</p>")

  // JSON clients are unaffected.
  server.handle(builder, request(http.Get, "/missing"))
  |> rendered_body
  |> should.equal("{\"error\":\"not found\"}")
}

pub fn panics_are_negotiated_test() {
  let builder =
    server.new(router.new() |> router.get("/boom", fn(_, _) { panic }), Nil)
  let res =
    server.handle(
      builder,
      request(http.Get, "/boom") |> request.set_header("accept", "text/plain"),
    )
  res.status |> should.equal(500)
  rendered_body(res) |> should.equal("internal server error")
}

fn conditional(method: http.Method, if_none_match: String) {
  let req = case if_none_match {
    "" -> request(method, "/")
    tag -> request(method, "/") |> request.set_header("if-none-match", tag)
  }
  use <- reply.fresh(req, "v7")
  reply.text(200, "page")
}

pub fn fresh_builds_the_page_with_its_etag_test() {
  let res = conditional(http.Get, "")
  res.status |> should.equal(200)
  header(res, "etag") |> should.equal("\"v7\"")
  res.body |> should.equal(reply.Text("page"))

  conditional(http.Get, "\"v6\"").status |> should.equal(200)
}

pub fn fresh_answers_304_for_a_current_copy_test() {
  let res = conditional(http.Get, "\"v6\", W/\"v7\"")
  res.status |> should.equal(304)
  header(res, "etag") |> should.equal("\"v7\"")
  res.body |> should.equal(reply.Empty)

  conditional(http.Head, "*").status |> should.equal(304)
}

pub fn fresh_refuses_unsafe_methods_on_a_match_test() {
  conditional(http.Put, "\"v7\"").status |> should.equal(412)
  conditional(http.Put, "\"v6\"").status |> should.equal(200)
}

pub fn fresh_keeps_quoted_and_weak_tags_and_skips_errors_test() {
  let req = request(http.Get, "/")
  {
    use <- reply.fresh(req, "W/\"a\"")
    reply.text(200, "")
  }
  |> header("etag")
  |> should.equal("W/\"a\"")

  let res = {
    use <- reply.fresh(req, "a")
    reply.not_found()
  }
  res.status |> should.equal(404)
  response.get_header(res, "etag") |> should.equal(Error(Nil))
}

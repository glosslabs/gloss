import gleam/http
import gleam/http/request
import gleam/int
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import gloss/http/query
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import http_support.{rendered_body, request}

fn with_query(q: String) {
  request.Request(..request(http.Get, "/"), query: Some(q))
}

pub fn read_test() {
  let req = with_query("page=2&tag=a&tag=b%20c&q=x+y&empty=")
  query.get(req, "page") |> should.equal(Ok("2"))
  query.get(req, "q") |> should.equal(Ok("x y"))
  query.get(req, "empty") |> should.equal(Ok(""))
  query.get(req, "missing") |> should.equal(Error(Nil))
  query.get_all(req, "tag") |> should.equal(["a", "b c"])
  query.all(request(http.Get, "/")) |> should.equal([])
}

fn app(q: String) {
  let routes =
    router.new()
    |> router.get("/", fn(req, _) {
      use page <- query.optional_int(req, "page", 1)
      use size <- query.int(req, "size")
      use sort <- query.string(req, "sort")
      reply.text(
        200,
        string.join([int.to_string(page), int.to_string(size), sort], ","),
      )
    })
  server.handle(server.new(routes, Nil), with_query(q))
}

pub fn helpers_test() {
  app("size=10&sort=name") |> rendered_body |> should.equal("1,10,name")
  app("page=3&size=10&sort=name") |> rendered_body |> should.equal("3,10,name")
  app("page=x&size=10&sort=name").status |> should.equal(400)
  app("size=ten&sort=name").status |> should.equal(400)
  app("size=10").status |> should.equal(400)
}

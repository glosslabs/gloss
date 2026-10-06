import gleam/dict
import gleam/http
import gleam/option.{None, Some}
import gleeunit/should
import gloss/http/router.{type Router}
import http_support.{answer, body, ctx, header, request, trail}

fn serve(r: Router(Nil), method: http.Method, path: String) {
  let assert Ok(table) = router.table(r)
  case router.match(table, method, path) {
    router.Matched(handler:, params:, route:) -> {
      let res = handler(request(method, path), http_support.ctx(Nil))
      #(res.status, body(res), params, route, header(res, "x-trail"))
    }
    router.MethodNotAllowed(handler:, ..) | router.NotFound(handler:) -> {
      let res = handler(request(method, path), ctx(Nil))
      #(res.status, header(res, "allow"), dict.new(), "", "")
    }
  }
}

pub fn static_param_and_wildcard_priority_test() {
  let r =
    router.new()
    |> router.get("/files/new", answer("static"))
    |> router.get("/files/:id", answer("param"))
    |> router.get("/files/*path", answer("wildcard"))

  let #(_, b, _, route, _) = serve(r, http.Get, "/files/new")
  b |> should.equal("static")
  route |> should.equal("/files/new")

  let #(_, b, params, route, _) = serve(r, http.Get, "/files/7")
  b |> should.equal("param")
  params |> should.equal(dict.from_list([#("id", "7")]))
  route |> should.equal("/files/:id")

  let #(_, b, params, _, _) = serve(r, http.Get, "/files/a/b%20c")
  b |> should.equal("wildcard")
  params |> should.equal(dict.from_list([#("path", "a/b c")]))
}

pub fn params_are_percent_decoded_test() {
  let r = router.new() |> router.get("/users/:name", answer("u"))
  let #(_, _, params, _, _) = serve(r, http.Get, "/users/ada%20l")
  params |> should.equal(dict.from_list([#("name", "ada l")]))
}

pub fn method_falls_back_to_a_less_specific_path_test() {
  let r =
    router.new()
    |> router.get("/users/new", answer("form"))
    |> router.post("/users/:id", answer("update"))
  let #(status, b, _, _, _) = serve(r, http.Post, "/users/new")
  status |> should.equal(200)
  b |> should.equal("update")
}

pub fn not_found_and_method_not_allowed_test() {
  let r =
    router.new()
    |> router.get("/notes", answer("index"))
    |> router.post("/notes", answer("create"))

  let #(status, _, _, _, _) = serve(r, http.Get, "/nope")
  status |> should.equal(404)

  let #(status, allow, _, _, _) = serve(r, http.Delete, "/notes")
  status |> should.equal(405)
  allow |> should.equal("GET, HEAD, POST")
}

pub fn head_falls_back_to_get_test() {
  let r = router.new() |> router.get("/notes", answer("index"))
  let #(status, b, _, _, _) = serve(r, http.Head, "/notes")
  status |> should.equal(200)
  b |> should.equal("index")
}

pub fn trailing_and_repeated_slashes_are_ignored_test() {
  let r = router.group("/notes") |> router.get("/", answer("index"))
  let #(status, _, _, route, _) = serve(r, http.Get, "/notes/")
  status |> should.equal(200)
  route |> should.equal("/notes")
  let #(status, _, _, _, _) = serve(r, http.Get, "//notes")
  status |> should.equal(200)
}

pub fn group_prefix_and_middleware_test() {
  let auth =
    router.group("/auth")
    |> router.get("/before", answer("b"))
    |> router.with(trail("A"))
    |> router.with(trail("B"))
    |> router.get("/me", answer("me"))
  let public = router.new() |> router.get("/health", answer("ok"))
  let r = router.combine([auth, public])

  // Middleware applies to routes added before and after `with`; the first
  // attached runs outermost, so it adds its mark last on the way out.
  let #(_, b, _, _, trail) = serve(r, http.Get, "/auth/me")
  b |> should.equal("me")
  trail |> should.equal("BA")
  let #(_, _, _, _, trail) = serve(r, http.Get, "/auth/before")
  trail |> should.equal("BA")

  // A sibling group is untouched.
  let #(_, _, _, _, trail) = serve(r, http.Get, "/health")
  trail |> should.equal("")
}

pub fn nested_combine_test() {
  let inner =
    router.group("/v1")
    |> router.with(trail("i"))
    |> router.get("/x", answer("x"))
  let r =
    router.combine([router.combine([inner])])
    |> router.with(trail("o"))
  let #(status, _, _, _, trail) = serve(r, http.Get, "/v1/x")
  status |> should.equal(200)
  trail |> should.equal("io")
}

pub fn params_in_group_prefix_test() {
  let r = router.group("/orgs/:org") |> router.get("/members/:id", answer("m"))
  let #(_, _, params, route, _) = serve(r, http.Get, "/orgs/acme/members/3")
  params |> should.equal(dict.from_list([#("org", "acme"), #("id", "3")]))
  route |> should.equal("/orgs/:org/members/:id")
}

pub fn duplicates_are_reported_test() {
  let a = router.new() |> router.get("/notes/:id", answer("a"))
  let b = router.new() |> router.get("/notes/:slug", answer("b"))
  router.check(router.combine([a, b]))
  |> should.equal(Error([router.DuplicateRoute(http.Get, "/notes/:slug")]))
  router.check(a) |> should.equal(Ok(Nil))
}

pub fn custom_not_found_test() {
  let r =
    router.combine([
      router.new() |> router.get("/a", answer("a")),
      router.new() |> router.not_found(answer("custom")),
    ])
  let assert Ok(table) = router.table(r)
  let assert router.NotFound(handler:) = router.match(table, http.Get, "/zz")
  handler(request(http.Get, "/zz"), ctx(Nil)) |> body |> should.equal("custom")
}

pub fn allowed_methods_test() {
  let r =
    router.new()
    |> router.get("/notes", answer("i"))
    |> router.delete("/notes/:id", answer("d"))
  let assert Ok(table) = router.table(r)
  router.allowed_methods(table, "/notes")
  |> should.equal([http.Get, http.Head])
  router.allowed_methods(table, "/notes/1") |> should.equal([http.Delete])
  router.allowed_methods(table, "/other") |> should.equal([])
}

pub fn inspect_test() {
  let r =
    router.group("/notes")
    |> router.get("/", answer("i"))
    |> router.describe("list notes")
    |> router.post("/:id", answer("u"))
  router.inspect(r)
  |> should.equal([
    router.RouteInfo(http.Get, "/notes", Some("list notes")),
    router.RouteInfo(http.Post, "/notes/:id", None),
  ])
}

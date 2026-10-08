import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gloss/http/context
import gloss/http/debug_bar.{type DebugBar}
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import gloss/http/session
import gloss/http/session/memory
import gloss/meta
import gloss/tracer
import http_support.{header, rendered_body, request}

const page = "<!doctype html><html><body><p>hi</p></body></html>"

fn app(bar: DebugBar) {
  router.new()
  |> router.get("/page", fn(_req, ctx: context.Context(Nil)) {
    // Work the panel should show: a span inside the request, as gloss/sql
    // records a query, and a log line.
    use <- tracer.span(ctx.tracer, "gloss.sql", "query", fn() {
      [#("sql", meta.String("select 1"))]
    })
    ctx.log.info("rendering", [#("user", meta.Int(7))])
    reply.html(200, page)
  })
  |> router.get("/api", fn(_, _) { reply.json(200, json.object([])) })
  |> router.get("/fragment", fn(_, _) { reply.html(200, "<p>no body tag</p>") })
  |> server.new(Nil)
  |> server.tracer(tracer.new() |> tracer.handle(debug_bar.handler(bar)))
  |> server.logger(debug_bar.logger(bar))
  |> server.with(debug_bar.middleware(bar))
}

fn get(bar: DebugBar, path: String) {
  server.handle(app(bar), request(http.Get, path))
}

pub fn html_pages_get_the_panel_test() {
  let assert Ok(bar) = debug_bar.start()
  let res = get(bar, "/page")
  let html = rendered_body(res)
  let trace_id = header(res, "x-request-id")
  assert string.contains(
    html,
    "<script src=\"/_gloss/debug/bar.js\" data-trace=\""
      <> trace_id
      <> "\" defer></script></body>",
  )
  assert string.contains(
    html,
    "<link rel=\"stylesheet\" href=\"/_gloss/debug/bar.css\">",
  )

  // Other responses are left alone.
  assert !string.contains(rendered_body(get(bar, "/api")), "bar.js")
  assert rendered_body(get(bar, "/fragment")) == "<p>no body tag</p>"
}

pub fn the_panel_assets_are_served_test() {
  let assert Ok(bar) = debug_bar.start()
  let js = get(bar, "/_gloss/debug/bar.js")
  assert js.status == 200
  assert header(js, "content-type") == "text/javascript; charset=utf-8"
  assert string.contains(rendered_body(js), "gloss-debug")
  let css = get(bar, "/_gloss/debug/bar.css")
  assert header(css, "content-type") == "text/css; charset=utf-8"
  assert get(bar, "/_gloss/debug/nothing").status == 404
}

pub fn a_trace_holds_the_request_its_spans_and_logs_test() {
  let assert Ok(bar) = debug_bar.start()
  let trace_id = header(get(bar, "/page"), "x-request-id")

  let res = get(bar, "/_gloss/debug/traces/" <> trace_id)
  assert header(res, "cache-control") == "no-store"
  let item = {
    use kind <- decode.field("kind", decode.string)
    use name <- decode.optional_field("name", "", decode.string)
    use message <- decode.optional_field("message", "", decode.string)
    decode.success(#(kind, name, message))
  }
  let assert Ok(items) =
    json.parse(rendered_body(res), decode.at(["items"], decode.list(item)))
  assert list.contains(items, #("span", "query", ""))
  assert list.contains(items, #("log", "", "rendering"))
  assert list.contains(items, #("span", "GET /page", ""))
}

pub fn recent_requests_leave_out_the_panel_test() {
  let assert Ok(bar) = debug_bar.start()
  let _ = get(bar, "/page")
  let _ = get(bar, "/api")
  let _ = get(bar, "/_gloss/debug/bar.js")
  let assert Ok(names) =
    json.parse(
      rendered_body(get(bar, "/_gloss/debug/requests")),
      decode.list(decode.at(["name"], decode.string)),
    )
  // Newest first.
  assert names == ["GET /api", "GET /page"]
}

pub fn logs_outside_a_request_are_ignored_test() {
  let assert Ok(bar) = debug_bar.start()
  debug_bar.logger(bar).info("booted", [])
  let _ = request.new()
  assert rendered_body(get(bar, "/_gloss/debug/traces/none"))
    == "{\"trace_id\":\"none\",\"items\":[]}"
}

fn session_app(bar: DebugBar) {
  let assert Ok(store) = memory.start()
  router.new()
  |> router.post("/login", fn(req, ctx: context.Context(Nil)) {
    use s <- session.load(req, ctx.sessions)
    s
    |> session.regenerate
    |> session.set("user_id", "7")
    |> session.save(reply.html(200, page))
  })
  |> router.get("/plain", fn(_, _) { reply.html(200, page) })
  |> server.new(Nil)
  |> server.sessions(session.new(store))
  |> server.tracer(tracer.new() |> tracer.handle(debug_bar.handler(bar)))
  |> server.with(debug_bar.middleware(bar))
}

fn session_item(app, trace_id: String) {
  let res =
    server.handle(app, request(http.Get, "/_gloss/debug/traces/" <> trace_id))
  let data = decode.optional(decode.dict(decode.string, decode.string))
  let item = {
    use kind <- decode.field("kind", decode.string)
    case kind {
      "session" -> {
        use before <- decode.field("before", data)
        use after <- decode.field("after", data)
        decode.success(Ok(#(before, after)))
      }
      _ -> decode.success(Error(Nil))
    }
  }
  let assert Ok(items) =
    json.parse(rendered_body(res), decode.at(["items"], decode.list(item)))
  list.filter_map(items, fn(i) { i })
}

pub fn the_session_before_and_after_is_recorded_test() {
  let assert Ok(bar) = debug_bar.start()
  let app = session_app(bar)

  // Signing in starts a session.
  let res = server.handle(app, request(http.Post, "/login"))
  let assert Ok(cookie) = list.key_find(res.headers, "set-cookie")
  let assert [#(None, Some(after))] =
    session_item(app, header(res, "x-request-id"))
  assert dict.to_list(after) == [#("user_id", "7")]

  // A later request sees it unchanged.
  let assert Ok(#(_, id)) = string.split_once(cookie, "=")
  let assert Ok(#(id, _)) = string.split_once(id, ";")
  let res =
    server.handle(
      app,
      request(http.Get, "/plain")
        |> request.set_header("cookie", "session=" <> id),
    )
  let assert [#(Some(before), Some(after))] =
    session_item(app, header(res, "x-request-id"))
  assert before == after

  // No session, nothing recorded.
  let res = server.handle(app, request(http.Get, "/plain"))
  assert session_item(app, header(res, "x-request-id")) == []
}

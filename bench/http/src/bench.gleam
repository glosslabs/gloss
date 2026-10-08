//// Start one HTTP server for load testing: `gleam run -m bench -- <server>
//// <port>`, where server is `gloss`, `mist` or `cowboy`. Each answers the
//// same routes:
////
//// - `GET /` with a short plain-text body;
//// - `GET /json` with a small JSON object;
//// - `GET /users/:id/posts/:post` with the params echoed as text, among
////   twenty other routes, to exercise routing.
////
//// See `run.sh` for the load itself.

import argv
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gloss/http/context
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import mist

pub fn main() {
  case argv.load().arguments {
    [name, port] ->
      case int.parse(port) {
        Ok(port) -> start(name, port)
        Error(Nil) -> usage()
      }
    _ -> usage()
  }
}

fn usage() {
  io.println("usage: gleam run -m bench -- <gloss|mist|cowboy> <port>")
}

fn start(name: String, port: Int) {
  case name {
    "gloss" -> {
      let assert Ok(_) =
        gloss_router()
        |> server.new(Nil)
        |> server.bind("127.0.0.1")
        |> server.port(port)
        |> server.start
      Nil
    }
    "mist" -> {
      let assert Ok(_) =
        mist.new(mist_handler)
        |> mist.bind("127.0.0.1")
        |> mist.port(port)
        |> mist.start
      Nil
    }
    "cowboy" -> start_cowboy(port)
    _ -> usage()
  }
  io.println(name <> " listening on " <> int.to_string(port))
  process.sleep_forever()
}

const hello = "Hello, world!"

fn payload() -> json.Json {
  json.object([
    #("id", json.int(42)),
    #("name", json.string("gloss")),
    #("tags", json.array(["fast", "small"], json.string)),
  ])
}

/// Routes that never match the benchmarked paths, so the router has a
/// realistic table to search.
const filler = [
  "accounts", "billing", "comments", "drafts", "events", "files", "groups",
  "invites", "jobs", "keys", "labels", "messages", "notes", "orders", "pages",
  "queues", "reports", "settings", "tags", "teams",
]

// --- gloss ---------------------------------------------------------------------

fn gloss_router() -> router.Router(Nil) {
  let base =
    router.new()
    |> router.get("/", fn(_, _) { reply.text(200, hello) })
    |> router.get("/json", fn(_, _) { reply.json(200, payload()) })
    |> router.get("/users/:id/posts/:post", fn(_, ctx: context.Context(Nil)) {
      let assert Ok(id) = context.param(ctx, "id")
      let assert Ok(post) = context.param(ctx, "post")
      reply.text(200, id <> "/" <> post)
    })
  list.fold(filler, base, fn(r, name) {
    r
    |> router.get("/" <> name, fn(_, _) { reply.text(200, name) })
    |> router.get("/" <> name <> "/:id", fn(_, _) { reply.text(200, name) })
  })
}

// --- mist ----------------------------------------------------------------------

fn mist_handler(req: Request(a)) -> response.Response(mist.ResponseData) {
  let #(status, content_type, body) = case request.path_segments(req) {
    [] -> #(200, "text/plain; charset=utf-8", hello)
    ["json"] -> #(200, "application/json", json.to_string(payload()))
    ["users", id, "posts", post] -> #(
      200,
      "text/plain; charset=utf-8",
      id <> "/" <> post,
    )
    [name] | [name, _] ->
      case list.contains(filler, name) {
        True -> #(200, "text/plain; charset=utf-8", name)
        False -> #(404, "text/plain; charset=utf-8", "not found")
      }
    _ -> #(404, "text/plain; charset=utf-8", "not found")
  }
  response.new(status)
  |> response.set_header("content-type", content_type)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

// --- cowboy --------------------------------------------------------------------

@external(erlang, "bench_cowboy", "start")
fn start_cowboy(port: Int) -> Nil

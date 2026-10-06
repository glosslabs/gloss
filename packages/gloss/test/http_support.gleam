import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/http.{type Method}
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/result
import gloss/http/context.{type Context, type Handler, type Middleware, Context}
import gloss/http/reply.{type Request, type Response}
import gloss/http/traceparent
import gloss/internal/http_reply_render as reply_render
import gloss/logger
import gloss/tracer

pub fn request(method: Method, path: String) -> Request {
  request.new()
  |> request.set_method(method)
  |> request.set_path(path)
  |> request.set_body(<<>>)
}

pub fn ctx(state: state) -> Context(state) {
  Context(
    state:,
    params: dict.new(),
    route: "",
    request_id: "test",
    trace: traceparent.new(),
    log: logger.discard(),
    tracer: tracer.new(),
  )
}

/// A handler that answers 200 with `label` as the body.
pub fn answer(label: String) -> Handler(state) {
  fn(_, _) { reply.text(200, label) }
}

/// A middleware that appends `label` to the `x-trail` header on the way out.
pub fn trail(label: String) -> Middleware(state) {
  fn(next) {
    fn(req, ctx) {
      let res = next(req, ctx)
      let previous = response.get_header(res, "x-trail") |> result.unwrap("")
      response.set_header(res, "x-trail", previous <> label)
    }
  }
}

/// The body as the server would send it to a client with no `Accept`
/// header.
pub fn body(res: Response) -> String {
  rendered_body(render(res, Error(Nil)))
}

/// A response as the server would send it for this `Accept` header. Only
/// for bodies held in memory.
pub fn render(
  res: Response,
  accept: Result(String, Nil),
) -> response.Response(BytesTree) {
  let rendered = reply_render.render(res, accept, reply.default_error_page)
  let assert reply_render.Sized(tree) = rendered.body
  response.set_body(rendered, tree)
}

pub fn rendered_body(res: response.Response(BytesTree)) -> String {
  let assert Ok(text) =
    res.body |> bytes_tree.to_bit_array |> bit_array.to_string
  text
}

pub fn header(res: response.Response(a), name: String) -> String {
  response.get_header(res, name) |> result.unwrap("")
}

/// Everything currently queued on a subject, in order, without waiting.
pub fn drain(subject: Subject(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(x) -> [x, ..drain(subject)]
    Error(Nil) -> []
  }
}

pub fn find(items: List(a), keep: fn(a) -> Bool) -> a {
  let assert Ok(item) = list.find(items, keep)
  item
}

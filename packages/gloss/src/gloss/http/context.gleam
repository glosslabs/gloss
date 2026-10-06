//// What a handler knows about the request it is serving, beyond the
//// request itself.
////
//// ```gleam
//// pub fn show(req: Request, ctx: Context(App)) -> Response {
////   use id <- context.int_param(ctx, "id")
////   ctx.log.info("fetching note", [])
////   case notes.get(ctx.state.notes, id) {
////     Ok(note) -> reply.json(200, note_json(note))
////     Error(Nil) -> reply.not_found()
////   }
//// }
//// ```

import gleam/dict.{type Dict}
import gleam/int
import gloss/http/reply.{type Request, type Response}
import gloss/logger.{type Logger}
import gloss/tracer.{type Tracer}

pub type Context(state) {
  Context(
    /// The application's own context, as given to `server.new`. Middleware
    /// may replace it, e.g. to attach the signed-in user.
    state: state,
    /// Path parameters captured by the route, percent-decoded.
    params: Dict(String, String),
    /// The template of the matched route, e.g. `"/notes/:id"`, or `""`
    /// when no route matched.
    route: String,
    /// The `x-request-id` the client sent, or a generated one.
    request_id: String,
    /// The server's logger with `request_id` and `route` added to every
    /// entry.
    log: Logger,
    tracer: Tracer,
  )
}

pub type Handler(state) =
  fn(Request, Context(state)) -> Response

/// Wraps a handler. Middleware attached first runs outermost.
///
/// ```gleam
/// pub fn authenticate(next: Handler(App)) -> Handler(App) {
///   fn(req: Request, ctx: Context(App)) {
///     case user_from(req) {
///       Ok(user) -> next(req, Context(..ctx, state: App(..ctx.state, user: Some(user))))
///       Error(Nil) -> reply.unauthorized()
///     }
///   }
/// }
/// ```
pub type Middleware(state) =
  fn(Handler(state)) -> Handler(state)

/// The path parameter `name`.
pub fn param(ctx: Context(state), name: String) -> Result(String, Nil) {
  dict.get(ctx.params, name)
}

/// Continue with the path parameter `name`, or answer 400 when the route
/// has no such parameter.
pub fn string_param(
  ctx: Context(state),
  name: String,
  next: fn(String) -> Response,
) -> Response {
  case param(ctx, name) {
    Ok(value) -> next(value)
    Error(Nil) -> reply.bad_request("missing path parameter " <> name)
  }
}

/// Continue with the path parameter `name` parsed as an integer, or answer
/// 400 when it is missing or not an integer.
pub fn int_param(
  ctx: Context(state),
  name: String,
  next: fn(Int) -> Response,
) -> Response {
  use value <- string_param(ctx, name)
  case int.parse(value) {
    Ok(n) -> next(n)
    Error(Nil) ->
      reply.bad_request("path parameter " <> name <> " must be an integer")
  }
}

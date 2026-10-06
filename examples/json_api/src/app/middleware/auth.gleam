import app/state.{type State, State, User}
import gleam/http/request
import gleam/option.{Some}
import gloss/http/context.{type Context, type Handler, Context}
import gloss/http/reply.{type Request}

/// Require `authorization: Bearer <API_TOKEN>`, and set `ctx.state.user` for
/// the handlers behind it. Anything else is answered `401`.
pub fn authenticate(next: Handler(State)) -> Handler(State) {
  fn(req: Request, ctx: Context(State)) {
    case request.get_header(req, "authorization") {
      Ok("Bearer " <> token) if token == ctx.state.api_token -> {
        let state = State(..ctx.state, user: Some(User(name: "api")))
        next(req, Context(..ctx, state:))
      }
      _ -> reply.unauthorized()
    }
  }
}

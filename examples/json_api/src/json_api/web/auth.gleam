import gleam/http/request
import gleam/option.{Some}
import gloss/http/context.{type Context, type Handler, Context}
import gloss/http/reply.{type Request}
import json_api/app.{type App, App, User}

/// Require `authorization: Bearer <API_TOKEN>`, and set `ctx.app.user` for
/// the handlers behind it. Anything else is answered `401`.
pub fn authenticate(next: Handler(App)) -> Handler(App) {
  fn(req: Request, ctx: Context(App)) {
    case request.get_header(req, "authorization") {
      Ok("Bearer " <> token) if token == ctx.app.api_token -> {
        let app = App(..ctx.app, user: Some(User(name: "api")))
        next(req, Context(..ctx, app:))
      }
      _ -> reply.unauthorized()
    }
  }
}

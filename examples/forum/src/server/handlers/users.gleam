import domain/accounts
import gloss/http/context.{type Context}
import gloss/http/reply.{type Request, type Response}
import server/state.{type State}
import server/views/layout
import server/views/profile as views

pub fn show(_req: Request, ctx: Context(State)) -> Response {
  use id <- context.int_param(ctx, "id")
  case accounts.get(ctx.state.accounts, id) {
    Ok(user) ->
      layout.page(200, user.display_name, ctx.state.user, views.show(user))
    Error(Nil) -> reply.not_found()
  }
}

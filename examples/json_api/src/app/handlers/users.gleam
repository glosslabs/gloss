import app/state.{type State}
import gleam/json
import gleam/option.{None, Some}
import gloss/http/context.{type Context}
import gloss/http/reply.{type Request, type Response}

/// The signed-in user. Behind `auth.authenticate`.
pub fn me(_req: Request, ctx: Context(State)) -> Response {
  case ctx.state.user {
    Some(user) ->
      reply.json(200, json.object([#("name", json.string(user.name))]))
    None -> reply.unauthorized()
  }
}

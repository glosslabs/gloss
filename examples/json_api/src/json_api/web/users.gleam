import gleam/json
import gleam/option.{None, Some}
import gloss/http/context.{type Context}
import gloss/http/reply.{type Request, type Response}
import json_api/app.{type App}

/// The signed-in user. Behind `auth.authenticate`.
pub fn me(_req: Request, ctx: Context(App)) -> Response {
  case ctx.app.user {
    Some(user) ->
      reply.json(200, json.object([#("name", json.string(user.name))]))
    None -> reply.unauthorized()
  }
}

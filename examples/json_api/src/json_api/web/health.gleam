import gleam/json
import gloss/http/context.{type Context}
import gloss/http/reply.{type Request, type Response}
import json_api/app.{type App}

pub fn show(_req: Request, _ctx: Context(App)) -> Response {
  reply.json(200, json.object([#("status", json.string("ok"))]))
}

import app/state.{type State}
import gleam/json
import gloss/http/context.{type Context}
import gloss/http/reply.{type Request, type Response}

pub fn show(_req: Request, _ctx: Context(State)) -> Response {
  reply.json(200, json.object([#("status", json.string("ok"))]))
}

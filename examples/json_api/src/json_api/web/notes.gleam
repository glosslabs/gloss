import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gloss/http/body
import gloss/http/context.{type Context}
import gloss/http/reply.{type Request, type Response}
import gloss/meta
import json_api/app.{type App}
import json_api/notes.{type Note}

pub fn index(_req: Request, ctx: Context(App)) -> Response {
  let notes = notes.all(ctx.app.notes)
  reply.json(200, json.object([#("notes", json.array(notes, note_json))]))
}

pub fn show(_req: Request, ctx: Context(App)) -> Response {
  use id <- context.int_param(ctx, "id")
  case notes.get(ctx.app.notes, id) {
    Ok(note) -> reply.json(200, note_json(note))
    Error(Nil) -> reply.not_found()
  }
}

pub fn create(req: Request, ctx: Context(App)) -> Response {
  use input <- body.json(req, input_decoder())
  let note = notes.create(ctx.app.notes, input.title, input.body)
  ctx.log.info("note created", [#("note", meta.Int(note.id))])
  reply.json(201, note_json(note))
}

pub fn delete(_req: Request, ctx: Context(App)) -> Response {
  use id <- context.int_param(ctx, "id")
  case notes.delete(ctx.app.notes, id) {
    Ok(Nil) -> reply.empty(204)
    Error(Nil) -> reply.not_found()
  }
}

type Input {
  Input(title: String, body: String)
}

fn input_decoder() -> Decoder(Input) {
  use title <- decode.field("title", decode.string)
  use body <- decode.optional_field("body", "", decode.string)
  decode.success(Input(title:, body:))
}

fn note_json(note: Note) -> Json {
  json.object([
    #("id", json.int(note.id)),
    #("title", json.string(note.title)),
    #("body", json.string(note.body)),
  ])
}

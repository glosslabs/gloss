import app/notes.{type Note}
import app/state.{type State}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{None, Some}
import gloss/http/body
import gloss/http/context.{type Context}
import gloss/http/reply.{type Request, type Response}
import gloss/meta
import gloss/sql

pub fn index(_req: Request, ctx: Context(State)) -> Response {
  use notes <- or_failed(ctx, notes.all(ctx.state.notes))
  reply.json(200, json.object([#("notes", json.array(notes, note_json))]))
}

pub fn show(_req: Request, ctx: Context(State)) -> Response {
  use id <- context.int_param(ctx, "id")
  use found <- or_failed(ctx, notes.get(ctx.state.notes, id))
  case found {
    Some(note) -> reply.json(200, note_json(note))
    None -> reply.not_found()
  }
}

pub fn create(req: Request, ctx: Context(State)) -> Response {
  use input <- body.json(req, input_decoder())
  use note <- or_failed(
    ctx,
    notes.create(ctx.state.notes, input.title, input.body),
  )
  ctx.log.info("note created", [#("note", meta.Int(note.id))])
  reply.json(201, note_json(note))
}

pub fn delete(_req: Request, ctx: Context(State)) -> Response {
  use id <- context.int_param(ctx, "id")
  use deleted <- or_failed(ctx, notes.delete(ctx.state.notes, id))
  case deleted {
    True -> reply.empty(204)
    False -> reply.not_found()
  }
}

/// Continue with the result's value, or log the database error and answer
/// with a 500.
fn or_failed(
  ctx: Context(State),
  result: Result(a, sql.Error),
  next: fn(a) -> Response,
) -> Response {
  case result {
    Ok(value) -> next(value)
    Error(error) -> {
      ctx.log.error("notes query failed", [
        #("error", meta.String(sql.describe(error))),
      ])
      reply.internal_error()
    }
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

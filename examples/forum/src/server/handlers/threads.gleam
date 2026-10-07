import domain/accounts
import domain/forum
import domain/forum/thread
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gloss/http/body
import gloss/http/context.{type Context}
import gloss/http/query
import gloss/http/reply.{type Request, type Response}
import gloss/http/websocket
import lustre/element
import server/handlers/forms
import server/middleware/current_user
import server/state.{type State}
import server/views/layout
import server/views/threads as views

const per_page = 20

pub fn index(req: Request, ctx: Context(State)) -> Response {
  use number <- query.optional_int(req, "page", 1)
  let page = forum.page(ctx.state.forum, number, per_page)
  let authors =
    accounts.many(ctx.state.accounts, list.map(page.threads, thread.author_id))
  layout.page(200, "Threads", ctx.state.user, views.index(page, authors))
}

pub fn new(_req: Request, ctx: Context(State)) -> Response {
  use user <- current_user.require(ctx)
  layout.page(200, "New thread", Some(user), views.new("", "", None))
}

pub fn create(req: Request, ctx: Context(State)) -> Response {
  use user <- current_user.require(ctx)
  use form <- body.form(req)
  let title = forms.value(form, "title")
  let text = forms.value(form, "body")
  case forum.open_thread(ctx.state.forum, user.id, title, text) {
    Ok(created) -> reply.redirect("/threads/" <> int.to_string(created.id))
    Error(error) ->
      layout.page(
        422,
        "New thread",
        Some(user),
        views.new(title, text, Some(views.post_error(error))),
      )
  }
}

pub fn show(_req: Request, ctx: Context(State)) -> Response {
  use id <- context.int_param(ctx, "id")
  show_thread(ctx, id, 200, "", None)
}

pub fn reply(req: Request, ctx: Context(State)) -> Response {
  use user <- current_user.require(ctx)
  use id <- context.int_param(ctx, "id")
  use form <- body.form(req)
  let text = forms.value(form, "body")
  case forum.reply(ctx.state.forum, id, user.id, text) {
    Ok(updated) -> {
      let anchor = case list.last(updated.posts) {
        Ok(post) -> {
          // Readers with the thread open see the reply arrive.
          let _ =
            websocket.broadcast_text(
              live_group(id),
              views.post_item(post, Some(user)) |> element.to_string,
            )
          "#post-" <> int.to_string(post.id)
        }
        Error(Nil) -> ""
      }
      reply.redirect("/threads/" <> int.to_string(id) <> anchor)
    }
    Error(forum.ThreadNotFound) -> reply.not_found()
    Error(forum.InvalidReply(error)) ->
      show_thread(ctx, id, 422, text, Some(views.post_error(error)))
  }
}

/// A socket that receives each new reply to the thread as HTML, for
/// `live.js` to append.
pub fn live(req: Request, ctx: Context(State)) -> Response {
  use id <- context.int_param(ctx, "id")
  websocket.new(
    on_init: fn(conn) {
      websocket.join(conn, live_group(id))
      #(Nil, None)
    },
    // Readers only listen.
    on_message: fn(state, _conn, _message) { websocket.continue(state) },
    on_close: fn(_state, _reason) { Nil },
  )
  |> websocket.upgrade(req, ctx)
}

fn live_group(thread_id: Int) -> String {
  "forum/thread/" <> int.to_string(thread_id)
}

fn show_thread(
  ctx: Context(State),
  id: Int,
  status: Int,
  draft: String,
  error: Option(String),
) -> Response {
  case forum.get(ctx.state.forum, id) {
    Error(Nil) -> reply.not_found()
    Ok(found) -> {
      let authors =
        accounts.many(
          ctx.state.accounts,
          list.map(found.posts, fn(post) { post.author_id }),
        )
      layout.page(
        status,
        found.title,
        ctx.state.user,
        views.show(found, authors, ctx.state.user, draft, error),
      )
    }
  }
}

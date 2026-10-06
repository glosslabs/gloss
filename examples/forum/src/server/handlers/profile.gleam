import domain/accounts
import gleam/option.{None, Some}
import gloss/http/body
import gloss/http/context.{type Context}
import gloss/http/reply.{type Request, type Response}
import server/handlers/forms
import server/middleware/current_user
import server/state.{type State}
import server/uploads
import server/views/layout
import server/views/profile as views

pub fn edit(_req: Request, ctx: Context(State)) -> Response {
  use user <- current_user.require(ctx)
  layout.page(
    200,
    "Your profile",
    Some(user),
    views.edit(user, user.display_name, user.bio, None, None),
  )
}

pub fn update(req: Request, ctx: Context(State)) -> Response {
  use user <- current_user.require(ctx)
  use form <- body.form(req)
  let display_name = forms.value(form, "display_name")
  let bio = forms.value(form, "bio")
  case accounts.update_profile(ctx.state.accounts, user.id, display_name, bio) {
    Ok(_) -> reply.redirect("/profile")
    Error(error) ->
      layout.page(
        422,
        "Your profile",
        Some(user),
        views.edit(
          user,
          display_name,
          bio,
          Some(views.profile_error(error)),
          None,
        ),
      )
  }
}

pub fn upload_avatar(req: Request, ctx: Context(State)) -> Response {
  use user <- current_user.require(ctx)
  let dir = ctx.state.avatars_dir
  use received <- uploads.receive_avatar(req, dir, user.id)
  let failed = fn(status, message) {
    layout.page(
      status,
      "Your profile",
      Some(user),
      views.edit(user, user.display_name, user.bio, None, Some(message)),
    )
  }
  case received {
    Ok(name) ->
      case accounts.set_avatar(ctx.state.accounts, user.id, name) {
        Ok(Some(old)) -> {
          uploads.remove(dir, old)
          reply.redirect("/profile")
        }
        Ok(None) -> reply.redirect("/profile")
        Error(Nil) -> reply.not_found()
      }
    Error(uploads.NoFile) -> failed(422, "Choose an image to upload.")
    Error(uploads.UnsupportedType) ->
      failed(415, "Use a PNG, JPEG, GIF or WebP image.")
    Error(uploads.TooLarge) -> failed(413, "Use an image of at most 2 MB.")
    Error(uploads.WriteFailed) -> failed(500, "The image couldn't be saved.")
    Error(uploads.Unreadable(_)) -> failed(400, "The upload couldn't be read.")
  }
}

import domain/accounts
import gleam/option.{None, Some}
import gloss/http/body
import gloss/http/context.{type Context}
import gloss/http/reply.{type Request, type Response}
import gloss/http/upload
import server/handlers/forms
import server/middleware/current_user
import server/state.{type State}
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

/// The avatar image, streamed straight to disk by `gloss/http/upload`.
pub fn upload_avatar(req: Request, ctx: Context(State)) -> Response {
  use user <- current_user.require(ctx)
  let dir = ctx.state.avatars_dir
  let config =
    upload.new(field: "avatar", dir:)
    |> upload.max_bytes(max_avatar_bytes)
    |> upload.accept(["image/png", "image/jpeg", "image/gif", "image/webp"])
  use result <- upload.save(req, config)
  case result {
    Ok(file) ->
      case accounts.set_avatar(ctx.state.accounts, user.id, file.name) {
        Ok(replaced) -> {
          option.map(replaced, fn(old) { upload.delete(dir <> "/" <> old) })
          reply.redirect("/profile")
        }
        Error(Nil) -> {
          upload.delete(file.path)
          reply.not_found()
        }
      }
    Error(error) -> {
      let #(status, message) = case error {
        upload.NoFile -> #(422, "Choose an image to upload.")
        upload.UnsupportedType(_) -> #(
          415,
          "Use a PNG, JPEG, GIF or WebP image.",
        )
        upload.TooLarge(_) -> #(413, "Use an image of at most 2 MB.")
        upload.WriteFailed -> #(500, "The image couldn't be saved.")
        upload.Unreadable(_) -> #(400, "The upload couldn't be read.")
      }
      layout.page(
        status,
        "Your profile",
        Some(user),
        views.edit(user, user.display_name, user.bio, None, Some(message)),
      )
    }
  }
}

const max_avatar_bytes = 2_000_000

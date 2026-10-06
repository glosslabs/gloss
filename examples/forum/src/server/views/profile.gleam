import domain/accounts/user.{type User}
import gleam/option.{type Option}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import server/views/layout

pub fn edit(
  user: User,
  display_name: String,
  bio: String,
  profile_error: Option(String),
  avatar_error: Option(String),
) -> List(Element(Nil)) {
  [
    html.h1([], [html.text("Your profile")]),
    html.form([attribute.method("post"), attribute.action("/profile")], [
      layout.error(profile_error),
      layout.field(
        "Display name",
        html.input([
          attribute.name("display_name"),
          attribute.value(display_name),
          attribute.maxlength(user.max_display_name),
          attribute.required(True),
        ]),
      ),
      layout.field(
        "Bio",
        html.textarea([attribute.name("bio"), attribute.rows(4)], bio),
      ),
      html.button([], [html.text("Save profile")]),
    ]),
    html.h2([], [html.text("Avatar")]),
    layout.avatar(user),
    html.form(
      [
        attribute.method("post"),
        attribute.action("/profile/avatar"),
        attribute.enctype("multipart/form-data"),
      ],
      [
        layout.error(avatar_error),
        layout.field(
          "Image (PNG, JPEG, GIF or WebP, up to 2 MB)",
          html.input([
            attribute.type_("file"),
            attribute.name("avatar"),
            attribute.accept([
              "image/png",
              "image/jpeg",
              "image/gif",
              "image/webp",
            ]),
          ]),
        ),
        html.button([], [html.text("Upload avatar")]),
      ],
    ),
  ]
}

/// A user's public page.
pub fn show(user: User) -> List(Element(Nil)) {
  [
    html.h1([], [layout.avatar(user), html.text(user.display_name)]),
    html.p([attribute.class("body")], [html.text(user.bio)]),
    html.small([], [html.text("Joined " <> layout.time(user.joined_at))]),
  ]
}

pub fn profile_error(error: user.ProfileError) -> String {
  case error {
    user.DisplayNameMissing -> "Choose a display name."
    user.DisplayNameTooLong -> "Keep your display name shorter."
    user.BioTooLong -> "Keep your bio shorter."
  }
}

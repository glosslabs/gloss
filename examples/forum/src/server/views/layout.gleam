//// The page every view sits in, and rendering to a response.

import domain/accounts/user.{type User}
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import gloss/http/reply.{type Response}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// A full HTML page as a response.
pub fn page(
  status: Int,
  title: String,
  user: Option(User),
  content: List(Element(Nil)),
) -> Response {
  reply.html(status, document(title, user, content))
}

pub fn document(
  title: String,
  user: Option(User),
  content: List(Element(Nil)),
) -> String {
  html.html([attribute.attribute("lang", "en")], [
    html.head([], [
      html.meta([attribute.attribute("charset", "utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.content("width=device-width, initial-scale=1"),
      ]),
      html.title([], title <> " · Forum"),
      html.link([attribute.rel("stylesheet"), attribute.href("/assets/app.css")]),
    ]),
    html.body([], [nav(user), html.main([], content)]),
  ])
  |> element.to_document_string
}

fn nav(user: Option(User)) -> Element(Nil) {
  html.header([], [
    html.nav([], [
      html.a([attribute.href("/"), attribute.class("brand")], [
        html.text("Forum"),
      ]),
      ..case user {
        Some(user) -> [
          html.a([attribute.href("/threads/new")], [html.text("New thread")]),
          html.a([attribute.href("/profile")], [html.text(user.display_name)]),
          html.form([attribute.method("post"), attribute.action("/logout")], [
            html.button([], [html.text("Sign out")]),
          ]),
        ]
        None -> [
          html.a([attribute.href("/login")], [html.text("Sign in")]),
          html.a([attribute.href("/register")], [html.text("Register")]),
        ]
      }
    ]),
  ])
}

/// A form field with its label.
pub fn field(label: String, input: Element(Nil)) -> Element(Nil) {
  html.label([], [html.span([], [html.text(label)]), input])
}

/// An error message, when there is one.
pub fn error(message: Option(String)) -> Element(Nil) {
  case message {
    Some(message) -> html.p([attribute.class("error")], [html.text(message)])
    None -> element.none()
  }
}

/// The user's avatar, or their initial.
pub fn avatar(user: User) -> Element(Nil) {
  case user.avatar {
    Some(file) ->
      html.img([
        attribute.src("/avatars/" <> file),
        attribute.alt(""),
        attribute.class("avatar"),
      ])
    None ->
      html.span([attribute.class("avatar")], [
        html.text(string.uppercase(string.slice(user.display_name, 0, 1))),
      ])
  }
}

/// `2026-10-07 12:00`, in UTC.
pub fn time(at: Timestamp) -> String {
  timestamp.to_rfc3339(at, calendar.utc_offset)
  |> string.slice(0, 16)
  |> string.replace("T", " ")
}

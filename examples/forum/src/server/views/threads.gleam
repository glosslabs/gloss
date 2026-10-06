import domain/accounts/user.{type User}
import domain/forum.{type Page}
import domain/forum/thread.{type PostError, type Thread}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import server/views/layout

pub fn index(page: Page, authors: Dict(Int, User)) -> List(Element(Nil)) {
  [
    html.h1([], [html.text("Threads")]),
    case page.threads {
      [] -> html.p([], [html.text("No threads yet.")])
      threads ->
        html.ul(
          [attribute.class("threads")],
          list.map(threads, fn(thread) {
            html.li([], [
              html.a([attribute.href("/threads/" <> int.to_string(thread.id))], [
                html.text(thread.title),
              ]),
              html.small([], [
                html.text(
                  " by "
                  <> name(authors, thread.author_id(thread))
                  <> " · "
                  <> plural(thread.replies(thread), "reply", "replies")
                  <> " · "
                  <> layout.time(thread.last_activity),
                ),
              ]),
            ])
          }),
        )
    },
    html.nav([attribute.class("pages")], [
      case page.number > 1 {
        True -> page_link(page.number - 1, "← Newer")
        False -> element.none()
      },
      case page.has_next {
        True -> page_link(page.number + 1, "Older →")
        False -> element.none()
      },
    ]),
  ]
}

fn page_link(number: Int, label: String) -> Element(Nil) {
  html.a([attribute.href("/?page=" <> int.to_string(number))], [
    html.text(label),
  ])
}

pub fn show(
  thread: Thread,
  authors: Dict(Int, User),
  user: Option(User),
  reply: String,
  error: Option(String),
) -> List(Element(Nil)) {
  [
    html.h1([], [html.text(thread.title)]),
    html.ol(
      [attribute.class("posts")],
      list.map(thread.posts, fn(post) {
        html.li([attribute.id("post-" <> int.to_string(post.id))], [
          html.header([], [
            case dict.get(authors, post.author_id) {
              Ok(author) ->
                html.a([attribute.href("/users/" <> int.to_string(author.id))], [
                  layout.avatar(author),
                  html.text(author.display_name),
                ])
              Error(Nil) -> html.text("Someone")
            },
            html.small([], [html.text(" " <> layout.time(post.at))]),
          ]),
          html.p([attribute.class("body")], [html.text(post.body)]),
        ])
      }),
    ),
    case user {
      Some(_) ->
        html.form(
          [
            attribute.method("post"),
            attribute.action(
              "/threads/" <> int.to_string(thread.id) <> "/replies",
            ),
          ],
          [
            layout.error(error),
            layout.field(
              "Reply",
              html.textarea([attribute.name("body"), attribute.rows(5)], reply),
            ),
            html.button([], [html.text("Post reply")]),
          ],
        )
      None ->
        html.p([], [
          html.a([attribute.href("/login")], [html.text("Sign in")]),
          html.text(" to reply."),
        ])
    },
  ]
}

pub fn new(
  title: String,
  body: String,
  error: Option(String),
) -> List(Element(Nil)) {
  [
    html.h1([], [html.text("New thread")]),
    layout.error(error),
    html.form([attribute.method("post"), attribute.action("/threads")], [
      layout.field(
        "Title",
        html.input([
          attribute.name("title"),
          attribute.value(title),
          attribute.maxlength(thread.max_title),
          attribute.required(True),
        ]),
      ),
      layout.field(
        "Post",
        html.textarea([attribute.name("body"), attribute.rows(8)], body),
      ),
      html.button([], [html.text("Start thread")]),
    ]),
  ]
}

pub fn post_error(error: PostError) -> String {
  case error {
    thread.TitleMissing -> "Give the thread a title."
    thread.TitleTooLong ->
      "Keep the title under "
      <> int.to_string(thread.max_title)
      <> " characters."
    thread.BodyMissing -> "Write something first."
    thread.BodyTooLong ->
      "Keep posts under " <> int.to_string(thread.max_body) <> " characters."
  }
}

fn name(authors: Dict(Int, User), id: Int) -> String {
  case dict.get(authors, id) {
    Ok(author) -> author.display_name
    Error(Nil) -> "someone"
  }
}

fn plural(count: Int, one: String, many: String) -> String {
  case count {
    1 -> "1 " <> one
    n -> int.to_string(n) <> " " <> many
  }
}

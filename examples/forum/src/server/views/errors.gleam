import gleam/option.{None}
import gloss/http/reply.{type ErrorPage}
import lustre/element/html
import server/views/layout

/// The HTML page for errors, such as a missing thread.
pub fn page(error: ErrorPage) -> String {
  layout.document(error.title, None, [
    html.h1([], [html.text(error.title)]),
    html.p([], [html.text(error.message)]),
  ])
}

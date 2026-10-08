//// A posts table for the query tests.

import gloss/sql/query.{type Column, type Table}

pub type Posts

pub fn table() -> Table(Posts) {
  query.table("posts")
}

pub fn id() -> Column(Posts, Int) {
  query.int_column(table(), "id")
}

pub fn user_id() -> Column(Posts, Int) {
  query.int_column(table(), "user_id")
}

pub fn title() -> Column(Posts, String) {
  query.text_column(table(), "title")
}

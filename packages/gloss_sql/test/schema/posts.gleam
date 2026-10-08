//// A posts table for the query tests.

import gleam/dynamic/decode
import gloss/sql/query.{type Column, type Table}

pub type Posts

pub fn table() -> Table(Posts) {
  query.table("posts")
}

pub fn id() -> Column(Posts, Int) {
  query.column(table(), "id", decode.int, 0)
}

pub fn user_id() -> Column(Posts, Int) {
  query.column(table(), "user_id", decode.int, 0)
}

pub fn title() -> Column(Posts, String) {
  query.column(table(), "title", decode.string, "")
}

//// The posts table, as gloss/sql/query reads it. Its shape is in
//// app/db's schema.

import gleam/time/timestamp.{type Timestamp}
import gloss/sql/query.{type Column, type Table}

pub type Posts

pub fn table() -> Table(Posts) {
  query.table("posts")
}

pub fn id() -> Column(Posts, Int) {
  query.int_column(table(), "id")
}

pub fn thread_id() -> Column(Posts, Int) {
  query.int_column(table(), "thread_id")
}

pub fn author_id() -> Column(Posts, Int) {
  query.int_column(table(), "author_id")
}

pub fn body() -> Column(Posts, String) {
  query.text_column(table(), "body")
}

pub fn at() -> Column(Posts, Timestamp) {
  query.timestamp_column(table(), "at")
}

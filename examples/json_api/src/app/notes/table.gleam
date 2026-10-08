//// The notes table, as gloss/sql/query reads it.

import gloss/sql/query.{type Column, type Table}

pub type Notes

pub fn table() -> Table(Notes) {
  query.table("notes")
}

pub fn id() -> Column(Notes, Int) {
  query.int_column(table(), "id")
}

pub fn title() -> Column(Notes, String) {
  query.text_column(table(), "title")
}

pub fn body() -> Column(Notes, String) {
  query.text_column(table(), "body")
}

//// The threads table, as gloss/sql/query reads it. Its shape is in
//// app/db's schema.

import gleam/time/timestamp.{type Timestamp}
import gloss/sql/query.{type Column, type Table}

pub type Threads

pub fn table() -> Table(Threads) {
  query.table("threads")
}

pub fn id() -> Column(Threads, Int) {
  query.int_column(table(), "id")
}

pub fn title() -> Column(Threads, String) {
  query.text_column(table(), "title")
}

pub fn last_activity() -> Column(Threads, Timestamp) {
  query.timestamp_column(table(), "last_activity")
}

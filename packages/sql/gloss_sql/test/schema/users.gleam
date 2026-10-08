//// A users table for the query tests, as an app would describe it.

import gleam/option.{type Option}
import gloss/sql/query.{type Column, type Table}

pub type Users

pub fn table() -> Table(Users) {
  query.table("users")
}

pub fn id() -> Column(Users, Int) {
  query.int_column(table(), "id")
}

pub fn email() -> Column(Users, String) {
  query.text_column(table(), "email")
}

pub fn bio() -> Column(Users, Option(String)) {
  query.text_column(table(), "bio") |> query.nullable
}

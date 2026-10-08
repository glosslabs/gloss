//// A users table for the query tests, as an app would describe it.

import gleam/dynamic/decode
import gleam/option.{type Option}
import gloss/sql/query.{type Column, type Table}

pub type Users

pub fn table() -> Table(Users) {
  query.table("users")
}

pub fn id() -> Column(Users, Int) {
  query.column(table(), "id", decode.int, 0)
}

pub fn email() -> Column(Users, String) {
  query.column(table(), "email", decode.string, "")
}

pub fn bio() -> Column(Users, Option(String)) {
  query.column(table(), "bio", decode.string, "") |> query.nullable
}

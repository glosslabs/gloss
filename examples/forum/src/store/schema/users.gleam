//// The users table, as gloss/sql/query reads it. Its shape is in
//// app/db's schema.

import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}
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

pub fn display_name() -> Column(Users, String) {
  query.text_column(table(), "display_name")
}

pub fn bio() -> Column(Users, String) {
  query.text_column(table(), "bio")
}

pub fn avatar() -> Column(Users, Option(String)) {
  query.text_column(table(), "avatar") |> query.nullable
}

pub fn password_hash() -> Column(Users, String) {
  query.text_column(table(), "password_hash")
}

pub fn joined_at() -> Column(Users, Timestamp) {
  query.timestamp_column(table(), "joined_at")
}

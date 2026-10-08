//// The notes, kept in SQLite and queried with gloss/sql/query.

import app/notes/table
import gleam/option.{type Option}
import gleam/result
import gloss/sql
import gloss/sql/pool
import gloss/sql/query
import gloss/sqlite

pub type Note {
  Note(id: Int, title: String, body: String)
}

pub opaque type Notes {
  Notes(db: pool.Db)
}

pub type StartError {
  PoolFailed(pool.StartError)
  SchemaFailed(sql.Error)
}

/// Open the database and create the notes table if it doesn't exist yet.
pub fn start(database: sqlite.Config) -> Result(Notes, StartError) {
  use db <- result.try(
    pool.new(sqlite.driver(database))
    |> pool.start
    |> result.map_error(PoolFailed),
  )
  use Nil <- result.map(
    pool.script(db, schema) |> result.map_error(SchemaFailed),
  )
  Notes(db)
}

const schema =
  "
create table if not exists notes (
  id    integer primary key,
  title text not null,
  body  text not null default ''
);
"

/// Every note, oldest first.
pub fn all(notes: Notes) -> Result(List(Note), sql.Error) {
  query.from(table.table())
  |> query.order_by(table.id(), query.Asc)
  |> query.select(note())
  |> query.to_statement
  |> sql.label("notes.all")
  |> pool.all(notes.db, _)
}

pub fn get(notes: Notes, id: Int) -> Result(Option(Note), sql.Error) {
  query.from(table.table())
  |> query.where(query.eq(table.id(), id))
  |> query.select(note())
  |> query.to_statement
  |> sql.label("notes.get")
  |> pool.optional(notes.db, _)
}

pub fn create(
  notes: Notes,
  title: String,
  body: String,
) -> Result(Note, sql.Error) {
  query.insert(table.table(), [
    query.set(table.title(), title),
    query.set(table.body(), body),
  ])
  |> query.select(note())
  |> query.to_statement
  |> sql.label("notes.create")
  |> pool.one(notes.db, _)
}

/// Delete the note, saying whether there was one.
pub fn delete(notes: Notes, id: Int) -> Result(Bool, sql.Error) {
  query.delete(table.table())
  |> query.where(query.eq(table.id(), id))
  |> query.to_statement
  |> sql.label("notes.delete")
  |> pool.exec(notes.db, _)
  |> result.map(fn(deleted) { deleted > 0 })
}

fn note() -> query.Selection(table.Notes, Note) {
  use id <- query.field(table.id())
  use title <- query.field(table.title())
  use body <- query.field(table.body())
  query.done(Note(id:, title:, body:))
}

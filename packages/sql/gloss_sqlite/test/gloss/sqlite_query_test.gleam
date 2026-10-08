//// Queries from gloss/sql/query, run on SQLite.

import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gloss/sql
import gloss/sql/pool
import gloss/sql/query.{type Column, type Table}
import gloss/sqlite

type Authors

fn authors() -> Table(Authors) {
  query.table("authors")
}

fn author_id() -> Column(Authors, Int) {
  query.column(authors(), "id", decode.int, 0)
}

fn name() -> Column(Authors, String) {
  query.column(authors(), "name", decode.string, "")
}

type Notes

fn notes() -> Table(Notes) {
  query.table("notes")
}

fn note_id() -> Column(Notes, Int) {
  query.column(notes(), "id", decode.int, 0)
}

fn author() -> Column(Notes, Int) {
  query.column(notes(), "author", decode.int, 0)
}

fn body() -> Column(Notes, Option(String)) {
  query.column(notes(), "body", decode.string, "") |> query.nullable
}

fn start() -> pool.Db {
  let assert Ok(db) =
    pool.new(sqlite.driver(sqlite.memory())) |> pool.size(1) |> pool.start
  let assert Ok(Nil) =
    pool.script(
      db,
      "create table authors (id integer primary key, name text not null);
       create table notes (
         id integer primary key,
         author integer not null references authors (id),
         body text
       );",
    )
  db
}

fn ids(db: pool.Db, q: query.Query(kind, table, row)) -> List(row) {
  let assert Ok(rows) = query.to_statement(q) |> pool.all(db, _)
  rows
}

pub fn builds_and_runs_queries_test() {
  let db = start()
  let assert Ok(2) =
    query.insert_rows(authors(), [
      [query.set(name(), query.text("ada"))],
      [query.set(name(), query.text("grace"))],
    ])
    |> query.to_statement
    |> pool.exec(db, _)

  // RETURNING gives back the new row.
  let assert [first] =
    query.insert(notes(), [
      query.set(author(), query.int(1)),
      query.set(body(), query.some(query.text("hello"))),
    ])
    |> query.select({
      use id <- query.field(note_id())
      query.done(id)
    })
    |> ids(db, _)
  let assert Ok(1) =
    query.insert(notes(), [query.set(author(), query.int(2))])
    |> query.to_statement
    |> pool.exec(db, _)

  // A join, filtered, ordered and paged.
  let by_author =
    query.from(notes())
    |> query.join(
      authors(),
      on: query.eq(query.ref(author()), query.ref(author_id())),
    )
    |> query.where(query.in(query.ref(author()), [query.int(1), query.int(2)]))
    |> query.order_by(query.ref(note_id()), query.Asc)
    |> query.select({
      use who <- query.field(query.right(name()))
      use body <- query.field(query.left(body()))
      query.done(#(who, body))
    })
  assert ids(db, by_author) == [#("ada", Some("hello")), #("grace", None)]
  assert ids(db, by_author |> query.offset(1)) == [#("grace", None)]
  assert ids(db, by_author |> query.limit(1)) == [#("ada", Some("hello"))]

  // Grouping, a subquery and a raw fragment.
  let counts =
    query.from(notes())
    |> query.where(query.in_query(
      query.ref(author()),
      query.from(authors())
        |> query.where(query.raw("lower(name) like ?", [sql.Text("%a%")]))
        |> query.select({
          use id <- query.field(author_id())
          query.done(id)
        }),
    ))
    |> query.group_by(query.ref(author()))
    |> query.having(query.gte(query.count_all(), query.int(1)))
    |> query.order_by(query.ref(author()), query.Asc)
    |> query.select({
      use who <- query.field(author())
      use n <- query.expression(query.count_all(), decode.int, 0)
      query.done(#(who, n))
    })
  assert ids(db, counts) == [#(1, 1), #(2, 1)]

  // Update with RETURNING, then delete.
  let assert [None] =
    query.update(notes(), [query.set(body(), query.null())])
    |> query.where(query.eq(query.ref(note_id()), query.int(first)))
    |> query.select({
      use body <- query.field(body())
      query.done(body)
    })
    |> ids(db, _)
  let assert Ok(1) =
    query.delete(notes())
    |> query.where(query.eq(query.ref(author()), query.int(2)))
    |> query.to_statement
    |> pool.exec(db, _)

  // Writes with nothing to write run and change nothing.
  let assert Ok(_) =
    query.insert_rows(notes(), []) |> query.to_statement |> pool.exec(db, _)
  let assert Ok(_) =
    query.update(notes(), []) |> query.to_statement |> pool.exec(db, _)
  let count = {
    use n <- query.expression(query.count_all(), decode.int, 0)
    query.done(n)
  }
  assert ids(db, query.from(notes()) |> query.select(count)) == [1]
}

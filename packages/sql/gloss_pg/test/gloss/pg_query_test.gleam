//// Queries from gloss/sql/query, run on Postgres. Like pg_test, these run
//// only when GLOSS_TEST_PG_URL is set.

import envoy
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import gloss/pg
import gloss/sql
import gloss/sql/pool
import gloss/sql/query.{type Column, type Table}

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

fn start() -> Result(pool.Db, Nil) {
  use url <- result.try(envoy.get("GLOSS_TEST_PG_URL"))
  let assert Ok(config) = pg.from_url(url)
  let assert Ok(db) = pool.new(pg.driver(config)) |> pool.size(1) |> pool.start
  let assert Ok(Nil) =
    pool.script(
      db,
      "create temp table authors (id serial primary key, name text not null);
       create temp table notes (
         id serial primary key,
         author integer not null references authors (id),
         body text
       );",
    )
  Ok(db)
}

fn ids(db: pool.Db, q: query.Query(kind, table, row)) -> List(row) {
  let assert Ok(rows) = query.to_statement(q) |> pool.all(db, _)
  rows
}

pub fn builds_and_runs_queries_test() {
  case start() {
    Ok(db) -> run(db)
    Error(Nil) -> Nil
  }
}

fn run(db: pool.Db) -> Nil {
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

  // Several rows, one leaving out a column, which gets its default.
  let assert Ok(2) =
    query.insert_rows(notes(), [
      [query.set(author(), query.int(1))],
      [
        query.set(author(), query.int(1)),
        query.set(body(), query.some(query.text("x"))),
      ],
    ])
    |> query.to_statement
    |> pool.exec(db, _)
  let assert Ok(2) =
    query.delete(notes())
    |> query.where(query.gt(query.ref(note_id()), query.int(2)))
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

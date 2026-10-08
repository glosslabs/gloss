//// Queries from gloss/sql/query, run on MySQL, which has no RETURNING.
//// Like mysql_test, these run only when GLOSS_TEST_MYSQL_URL is set.

import envoy
import gleam/option.{type Option, None, Some}
import gleam/result
import gloss/mysql
import gloss/sql
import gloss/sql/pool
import gloss/sql/query.{type Column, type Table}

type Authors

fn authors() -> Table(Authors) {
  query.table("query_authors")
}

fn author_id() -> Column(Authors, Int) {
  query.int_column(authors(), "id")
}

fn name() -> Column(Authors, String) {
  query.text_column(authors(), "name")
}

type Notes

fn notes() -> Table(Notes) {
  query.table("query_notes")
}

fn note_id() -> Column(Notes, Int) {
  query.int_column(notes(), "id")
}

fn author() -> Column(Notes, Int) {
  query.int_column(notes(), "author")
}

fn body() -> Column(Notes, Option(String)) {
  query.text_column(notes(), "body") |> query.nullable
}

fn start() -> Result(pool.Db, Nil) {
  use url <- result.try(envoy.get("GLOSS_TEST_MYSQL_URL"))
  let assert Ok(config) = mysql.from_url(url)
  let assert Ok(db) =
    pool.new(mysql.driver(config)) |> pool.size(1) |> pool.start
  let assert Ok(Nil) =
    pool.script(
      db,
      "drop table if exists query_notes, query_authors;
       create table query_authors (
         id int auto_increment primary key, name text not null
       );
       create table query_notes (
         id int auto_increment primary key,
         author int not null references query_authors (id),
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
      [query.set(name(), "ada")],
      [query.set(name(), "grace")],
    ])
    |> query.to_statement
    |> pool.exec(db, _)

  let assert Ok(first) =
    query.insert(notes(), [
      query.set(author(), 1),
      query.set(body(), Some("hello")),
    ])
    |> query.to_statement
    |> mysql.insert_id(db, _)
  let assert Ok(1) =
    query.insert(notes(), [query.set(author(), 2)])
    |> query.to_statement
    |> pool.exec(db, _)

  // A join, filtered, ordered and paged.
  let by_author =
    query.from(notes())
    |> query.join(
      authors(),
      on: query.same(query.left(author()), query.right(author_id())),
    )
    |> query.where(query.in(query.left(author()), [1, 2]))
    |> query.order_by(query.left(note_id()), query.Asc)
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
      author(),
      query.from(authors())
        |> query.where(query.raw("lower(name) like ?", [sql.Text("%a%")]))
        |> query.select(query.only(author_id())),
    ))
    |> query.group_by(author())
    |> query.having(query.gte(query.count_all(), 1))
    |> query.order_by(author(), query.Asc)
    |> query.select({
      use who <- query.field(author())
      use n <- query.field(query.count_all())
      query.done(#(who, n))
    })
  assert ids(db, counts) == [#(1, 1), #(2, 1)]

  // Update, then delete.
  let assert Ok(1) =
    query.update(notes(), [query.set(body(), None)])
    |> query.where(query.eq(note_id(), first))
    |> query.to_statement
    |> pool.exec(db, _)
  let bodies =
    query.from(notes())
    |> query.where(query.eq(note_id(), first))
    |> query.select({
      use body <- query.field(body())
      query.done(body)
    })
  assert ids(db, bodies) == [None]
  let assert Ok(1) =
    query.delete(notes())
    |> query.where(query.eq(author(), 2))
    |> query.to_statement
    |> pool.exec(db, _)

  // Several rows, one leaving out a column, which gets its default.
  let assert Ok(2) =
    query.insert_rows(notes(), [
      [query.set(author(), 1)],
      [
        query.set(author(), 1),
        query.set(body(), Some("x")),
      ],
    ])
    |> query.to_statement
    |> pool.exec(db, _)
  let assert Ok(2) =
    query.delete(notes())
    |> query.where(query.gt(note_id(), 2))
    |> query.to_statement
    |> pool.exec(db, _)

  // Writes with nothing to write run and change nothing.
  let assert Ok(_) =
    query.insert_rows(notes(), []) |> query.to_statement |> pool.exec(db, _)
  let assert Ok(_) =
    query.update(notes(), []) |> query.to_statement |> pool.exec(db, _)
  let count = query.only(query.count_all())
  assert ids(db, query.from(notes()) |> query.select(count)) == [1]
}

import gleam/dynamic/decode
import gleam/option.{None, Some}
import gloss/sql
import gloss/sql/query
import schema/posts
import schema/users

type User {
  User(id: Int, email: String)
}

fn pg(query: query.Query(kind, table, row)) -> #(String, List(sql.Value)) {
  query.to_statement(query) |> sql.render(sql.Postgres)
}

fn text_of(
  query: query.Query(kind, table, row),
  dialect: sql.Dialect,
) -> String {
  { query.to_statement(query) |> sql.render(dialect) }.0
}

fn user() -> query.Selection(users.Users, User) {
  use id <- query.field(users.id())
  use email <- query.field(users.email())
  query.done(User(id:, email:))
}

pub fn select_everything_test() {
  assert pg(query.from(users.table())) == #("SELECT * FROM \"users\"", [])
}

pub fn select_with_clauses_test() {
  let q =
    query.from(users.table())
    |> query.where(query.eq(query.ref(users.email()), query.text("a@b.c")))
    |> query.where(query.is_null(query.ref(users.bio())))
    |> query.order_by(query.ref(users.id()), query.Desc)
    |> query.limit(10)
    |> query.offset(20)
    |> query.select(user())
  assert pg(q)
    == #(
      "SELECT \"users\".\"id\", \"users\".\"email\" FROM \"users\""
        <> " WHERE ((\"users\".\"email\" = $1) AND (\"users\".\"bio\" IS NULL))"
        <> " ORDER BY \"users\".\"id\" DESC LIMIT $2 OFFSET $3",
      [sql.Text("a@b.c"), sql.Int(10), sql.Int(20)],
    )
}

pub fn dialects_quote_and_number_differently_test() {
  let q =
    query.from(users.table())
    |> query.where(query.eq(query.ref(users.id()), query.int(1)))
  assert text_of(q, sql.Mysql)
    == "SELECT * FROM `users` WHERE (`users`.`id` = ?)"
  assert text_of(q, sql.Sqlite)
    == "SELECT * FROM \"users\" WHERE (\"users\".\"id\" = ?1)"
}

pub fn an_offset_alone_still_gets_a_limit_test() {
  let assert #(text, [sql.Int(_), sql.Int(5)]) =
    pg(query.from(users.table()) |> query.offset(5))
  assert text == "SELECT * FROM \"users\" LIMIT $1 OFFSET $2"
}

pub fn conditions_combine_test() {
  let id = query.ref(users.id())
  let q =
    query.from(users.table())
    |> query.where(
      query.or([
        query.in(id, [query.int(1), query.int(2)]),
        query.not(query.like(query.ref(users.email()), query.text("%@x"))),
        query.gte(id, query.int(100)),
      ]),
    )
  assert pg(q).0
    == "SELECT * FROM \"users\" WHERE ((\"users\".\"id\" IN ($1, $2))"
    <> " OR (NOT (\"users\".\"email\" LIKE $3)) OR (\"users\".\"id\" >= $4))"
}

pub fn empty_lists_are_constants_test() {
  let id = query.ref(users.id())
  let where = fn(condition) {
    pg(query.from(users.table()) |> query.where(condition)).0
  }
  assert where(query.in(id, [])) == "SELECT * FROM \"users\" WHERE FALSE"
  assert where(query.not_in(id, [])) == "SELECT * FROM \"users\" WHERE TRUE"
  assert where(query.and([])) == "SELECT * FROM \"users\" WHERE TRUE"
  assert where(query.or([])) == "SELECT * FROM \"users\" WHERE FALSE"
}

pub fn raw_fragments_number_their_arguments_test() {
  let q =
    query.from(users.table())
    |> query.where(query.eq(query.ref(users.id()), query.int(7)))
    |> query.where(
      query.raw("lower(email) = ? and data ?? 'key' and ? > 0", [
        sql.Text("a"),
        sql.Int(1),
      ]),
    )
  assert pg(q)
    == #(
      "SELECT * FROM \"users\" WHERE ((\"users\".\"id\" = $1)"
        <> " AND lower(email) = $2 and data ? 'key' and $3 > 0)",
      [sql.Int(7), sql.Text("a"), sql.Int(1)],
    )
}

pub fn joins_select_from_both_tables_test() {
  let q =
    query.from(users.table())
    |> query.join(
      posts.table(),
      on: query.eq(query.ref(posts.user_id()), query.ref(users.id())),
    )
    |> query.select({
      use email <- query.field(query.left(users.email()))
      use title <- query.field(query.right(posts.title()))
      query.done(#(email, title))
    })
  assert pg(q).0
    == "SELECT \"users\".\"email\", \"posts\".\"title\" FROM \"users\""
    <> " JOIN \"posts\" ON (\"posts\".\"user_id\" = \"users\".\"id\")"
  // A row decodes in the selection's order.
  let outcome =
    sql.Outcome(rows: [[sql.Text("a@b.c"), sql.Text("Hello")]], affected: 1)
  assert sql.all(outcome, query.to_statement(q)) == Ok([#("a@b.c", "Hello")])
}

pub fn subqueries_share_the_argument_numbering_test() {
  let authors =
    query.from(posts.table())
    |> query.where(query.eq(query.ref(posts.title()), query.text("Hi")))
    |> query.select({
      use id <- query.field(posts.user_id())
      query.done(id)
    })
  let q =
    query.from(users.table())
    |> query.where(query.gt(query.ref(users.id()), query.int(3)))
    |> query.where(query.in_query(query.ref(users.id()), authors))
    |> query.where(query.exists(query.from(posts.table())))
  assert pg(q)
    == #(
      "SELECT * FROM \"users\" WHERE (((\"users\".\"id\" > $1)"
        <> " AND (\"users\".\"id\" IN (SELECT \"posts\".\"user_id\" FROM \"posts\""
        <> " WHERE (\"posts\".\"title\" = $2))))"
        <> " AND EXISTS (SELECT * FROM \"posts\"))",
      [sql.Int(3), sql.Text("Hi")],
    )
}

pub fn grouping_and_counting_test() {
  let q =
    query.from(posts.table())
    |> query.group_by(query.ref(posts.user_id()))
    |> query.having(query.gt(query.count_all(), query.int(1)))
    |> query.distinct
    |> query.select({
      use user_id <- query.field(posts.user_id())
      use count <- query.expression(query.count_all(), decode.int, 0)
      query.done(#(user_id, count))
    })
  assert pg(q).0
    == "SELECT DISTINCT \"posts\".\"user_id\", count(*) FROM \"posts\""
    <> " GROUP BY \"posts\".\"user_id\" HAVING (count(*) > $1)"
  let outcome = sql.Outcome(rows: [[sql.Int(4), sql.Int(2)]], affected: 1)
  assert sql.all(outcome, query.to_statement(q)) == Ok([#(4, 2)])
}

pub fn nullable_columns_decode_as_options_test() {
  let q =
    query.from(users.table())
    |> query.where(query.eq(query.ref(users.bio()), query.some(query.text("x"))))
    |> query.select({
      use bio <- query.field(users.bio())
      query.done(bio)
    })
  let outcome =
    sql.Outcome(rows: [[sql.Null], [sql.Text("hello")]], affected: 2)
  assert sql.all(outcome, query.to_statement(q)) == Ok([None, Some("hello")])
}

pub fn a_row_that_does_not_match_fails_to_decode_test() {
  let q = query.from(users.table()) |> query.select(user())
  let outcome = sql.Outcome(rows: [[sql.Int(1), sql.Int(2)]], affected: 1)
  let assert Error(sql.DecodeFailed(row: 0, errors: [_])) =
    sql.all(outcome, query.to_statement(q))
  Nil
}

pub fn untyped_queries_use_names_test() {
  let q =
    query.from(query.table("audit.events"))
    |> query.where(query.eq(query.named("kind"), query.text("login")))
    |> query.select(query.columns([query.named("id"), query.named("at")]))
  assert pg(q)
    == #(
      "SELECT \"id\", \"at\" FROM \"audit\".\"events\" WHERE (\"kind\" = $1)",
      [sql.Text("login")],
    )
  let outcome = sql.Outcome(rows: [[sql.Int(1), sql.Text("now")]], affected: 1)
  let assert Ok([row]) = sql.all(outcome, query.to_statement(q))
  assert decode.run(row, decode.at([1], decode.string)) == Ok("now")
}

pub fn inserts_test() {
  let q =
    query.insert(users.table(), [
      query.set(users.email(), query.text("a@b.c")),
      query.set(users.bio(), query.null()),
    ])
    |> query.select(user())
  assert pg(q)
    == #(
      "INSERT INTO \"users\" (\"email\", \"bio\") VALUES ($1, NULL)"
        <> " RETURNING \"users\".\"id\", \"users\".\"email\"",
      [sql.Text("a@b.c")],
    )
}

pub fn inserting_several_rows_fills_gaps_with_defaults_test() {
  let q =
    query.insert_rows(users.table(), [
      [query.set(users.email(), query.text("a"))],
      [
        query.set(users.bio(), query.some(query.text("b"))),
        query.set(users.email(), query.text("c")),
      ],
    ])
  assert pg(q).0
    == "INSERT INTO \"users\" (\"email\", \"bio\") VALUES ($1, DEFAULT), ($2, $3)"
  assert pg(q).1 == [sql.Text("a"), sql.Text("c"), sql.Text("b")]
}

pub fn writes_with_nothing_to_write_do_nothing_test() {
  assert pg(query.insert_rows(users.table(), [])).0 == "SELECT 1 WHERE 1 = 0"
  assert pg(query.update(users.table(), [])).0 == "SELECT 1 WHERE 1 = 0"
  assert pg(query.insert(users.table(), [])).0
    == "INSERT INTO \"users\" DEFAULT VALUES"
}

pub fn updates_test() {
  let q =
    query.update(users.table(), [
      query.set(users.email(), query.text("new@b.c")),
    ])
    |> query.where(query.eq(query.ref(users.id()), query.int(1)))
    |> query.select({
      use id <- query.field(users.id())
      query.done(id)
    })
  assert pg(q)
    == #(
      "UPDATE \"users\" SET \"email\" = $1 WHERE (\"users\".\"id\" = $2)"
        <> " RETURNING \"users\".\"id\"",
      [sql.Text("new@b.c"), sql.Int(1)],
    )
}

pub fn deletes_test() {
  let q =
    query.delete(users.table())
    |> query.where(query.lt(query.ref(users.id()), query.int(10)))
  assert pg(q)
    == #("DELETE FROM \"users\" WHERE (\"users\".\"id\" < $1)", [sql.Int(10)])
}

pub fn statements_keep_labels_test() {
  let statement =
    query.from(users.table()) |> query.to_statement |> sql.label("users.all")
  assert sql.label_of(statement) == Some("users.all")
}

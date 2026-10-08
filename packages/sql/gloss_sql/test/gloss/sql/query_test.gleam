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
    |> query.where(query.eq(users.email(), "a@b.c"))
    |> query.where(query.eq(users.bio(), None))
    |> query.order_by(users.id(), query.Desc)
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

pub fn none_compares_as_null_test() {
  let where = fn(condition) {
    pg(query.from(users.table()) |> query.where(condition))
  }
  assert where(query.not_eq(users.bio(), None))
    == #("SELECT * FROM \"users\" WHERE (\"users\".\"bio\" IS NOT NULL)", [])
  assert where(query.eq(users.bio(), Some("x")))
    == #("SELECT * FROM \"users\" WHERE (\"users\".\"bio\" = $1)", [
      sql.Text("x"),
    ])
}

pub fn dialects_quote_and_number_differently_test() {
  let q = query.from(users.table()) |> query.where(query.eq(users.id(), 1))
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
  let q =
    query.from(users.table())
    |> query.where(
      query.or([
        query.in(users.id(), [1, 2]),
        query.not(query.like(users.email(), "%@x")),
        query.gte(users.id(), 100),
      ]),
    )
  assert pg(q).0
    == "SELECT * FROM \"users\" WHERE ((\"users\".\"id\" IN ($1, $2))"
    <> " OR (NOT (\"users\".\"email\" LIKE $3)) OR (\"users\".\"id\" >= $4))"
}

pub fn empty_lists_are_constants_test() {
  let where = fn(condition) {
    pg(query.from(users.table()) |> query.where(condition)).0
  }
  assert where(query.in(users.id(), []))
    == "SELECT * FROM \"users\" WHERE FALSE"
  assert where(query.not_in(users.id(), []))
    == "SELECT * FROM \"users\" WHERE TRUE"
  assert where(query.and([])) == "SELECT * FROM \"users\" WHERE TRUE"
  assert where(query.or([])) == "SELECT * FROM \"users\" WHERE FALSE"
}

pub fn when_applies_only_with_a_value_test() {
  let search = fn(term) {
    query.from(users.table())
    |> query.when(term, fn(q, term) {
      query.where(q, query.like(users.email(), "%" <> term <> "%"))
    })
    |> pg
  }
  assert search(None) == #("SELECT * FROM \"users\"", [])
  assert search(Some("ada"))
    == #("SELECT * FROM \"users\" WHERE (\"users\".\"email\" LIKE $1)", [
      sql.Text("%ada%"),
    ])
}

pub fn raw_fragments_number_their_arguments_test() {
  let q =
    query.from(users.table())
    |> query.where(query.eq(users.id(), 7))
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
      on: query.same(query.right(posts.user_id()), query.left(users.id())),
    )
    |> query.where(query.eq(query.right(posts.title()), "Hello"))
    |> query.select({
      use email <- query.field(query.left(users.email()))
      use title <- query.field(query.right(posts.title()))
      query.done(#(email, title))
    })
  assert pg(q).0
    == "SELECT \"users\".\"email\", \"posts\".\"title\" FROM \"users\""
    <> " JOIN \"posts\" ON (\"posts\".\"user_id\" = \"users\".\"id\")"
    <> " WHERE (\"posts\".\"title\" = $1)"
  // A row decodes in the selection's order.
  let outcome =
    sql.Outcome(rows: [[sql.Text("a@b.c"), sql.Text("Hello")]], affected: 1)
  assert sql.all(outcome, query.to_statement(q)) == Ok([#("a@b.c", "Hello")])
}

pub fn left_joins_read_the_joined_table_as_options_test() {
  let q =
    query.from(users.table())
    |> query.left_join(
      posts.table(),
      on: query.same(query.right(posts.user_id()), query.left(users.id())),
    )
    // Users with no posts.
    |> query.where(query.eq(query.maybe(posts.id()), None))
    |> query.select({
      use email <- query.field(query.left(users.email()))
      use title <- query.field(query.maybe(posts.title()))
      query.done(#(email, title))
    })
  assert pg(q).0
    == "SELECT \"users\".\"email\", \"posts\".\"title\" FROM \"users\""
    <> " LEFT JOIN \"posts\" ON (\"posts\".\"user_id\" = \"users\".\"id\")"
    <> " WHERE (\"posts\".\"id\" IS NULL)"
  let outcome =
    sql.Outcome(
      rows: [[sql.Text("a"), sql.Null], [sql.Text("b"), sql.Text("Hi")]],
      affected: 2,
    )
  assert sql.all(outcome, query.to_statement(q))
    == Ok([#("a", None), #("b", Some("Hi"))])
}

pub fn subqueries_share_the_argument_numbering_test() {
  let authors =
    query.from(posts.table())
    |> query.where(query.eq(posts.title(), "Hi"))
    |> query.select(query.only(posts.user_id()))
  let q =
    query.from(users.table())
    |> query.where(query.gt(users.id(), 3))
    |> query.where(query.in_query(users.id(), authors))
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
    |> query.group_by(posts.user_id())
    |> query.having(query.gt(query.count_all(), 1))
    |> query.distinct
    |> query.select({
      use user_id <- query.field(posts.user_id())
      use count <- query.field(query.count_all())
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
    |> query.where(query.eq(users.bio(), Some("x")))
    |> query.select(query.only(users.bio()))
  let outcome =
    sql.Outcome(rows: [[sql.Null], [sql.Text("hello")]], affected: 2)
  assert sql.all(outcome, query.to_statement(q)) == Ok([None, Some("hello")])
}

pub fn booleans_decode_from_integers_test() {
  let q =
    query.from(users.table())
    |> query.select(query.only(query.bool_column(users.table(), "admin")))
  let outcome =
    sql.Outcome(
      rows: [[sql.Int(1)], [sql.Int(0)], [sql.Bool(True)]],
      affected: 3,
    )
  assert sql.all(outcome, query.to_statement(q)) == Ok([True, False, True])
}

pub fn a_row_that_does_not_match_fails_to_decode_test() {
  let q = query.from(users.table()) |> query.select(user())
  let outcome = sql.Outcome(rows: [[sql.Int(1), sql.Int(2)]], affected: 1)
  let assert Error(sql.DecodeFailed(row: 0, errors: [_])) =
    sql.all(outcome, query.to_statement(q))
  Nil
}

pub fn custom_columns_use_their_own_codec_test() {
  let events = query.table("audit.events")
  let kind =
    query.column(
      events,
      "kind",
      decoder: decode.string |> decode.map(Kind),
      zero: Kind(""),
      encode: fn(kind: Kind) { sql.Text(kind.name) },
    )
  let q =
    query.from(events)
    |> query.where(query.eq(kind, Kind("login")))
    |> query.select(query.only(kind))
  assert pg(q)
    == #(
      "SELECT \"audit\".\"events\".\"kind\" FROM \"audit\".\"events\""
        <> " WHERE (\"audit\".\"events\".\"kind\" = $1)",
      [sql.Text("login")],
    )
  let outcome = sql.Outcome(rows: [[sql.Text("login")]], affected: 1)
  assert sql.all(outcome, query.to_statement(q)) == Ok([Kind("login")])
}

type Kind {
  Kind(name: String)
}

pub fn inserts_test() {
  let q =
    query.insert(users.table(), [
      query.set(users.email(), "a@b.c"),
      query.set(users.bio(), None),
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
      [query.set(users.email(), "a")],
      [query.set(users.bio(), Some("b")), query.set(users.email(), "c")],
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
    query.update(users.table(), [query.set(users.email(), "new@b.c")])
    |> query.where(query.eq(users.id(), 1))
    |> query.select(query.only(users.id()))
  assert pg(q)
    == #(
      "UPDATE \"users\" SET \"email\" = $1 WHERE (\"users\".\"id\" = $2)"
        <> " RETURNING \"users\".\"id\"",
      [sql.Text("new@b.c"), sql.Int(1)],
    )
}

pub fn deletes_test() {
  let q = query.delete(users.table()) |> query.where(query.lt(users.id(), 10))
  assert pg(q)
    == #("DELETE FROM \"users\" WHERE (\"users\".\"id\" < $1)", [sql.Int(10)])
}

pub fn statements_keep_labels_test() {
  let statement =
    query.from(users.table()) |> query.to_statement |> sql.label("users.all")
  assert sql.label_of(statement) == Some("users.all")
}

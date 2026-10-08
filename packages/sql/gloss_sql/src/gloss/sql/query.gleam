//// Build `gloss/sql` statements from tables, columns and expressions
//// instead of SQL text. A query is an immutable value: each function takes
//// one and returns a new one, so they chain with `|>`, and a reusable part
//// (a scope, a filter) is a plain function from query to query.
////
//// Describe each table once, in code you write or generate:
////
//// ```gleam
//// pub type Users
////
//// pub fn table() -> query.Table(Users) {
////   query.table("users")
//// }
////
//// pub fn id() -> query.Column(Users, Int) {
////   query.int_column(table(), "id")
//// }
////
//// pub fn email() -> query.Column(Users, String) {
////   query.text_column(table(), "email")
//// }
////
//// pub fn bio() -> query.Column(Users, Option(String)) {
////   query.text_column(table(), "bio") |> query.nullable
//// }
//// ```
////
//// Then build queries from them:
////
//// ```gleam
//// query.from(users.table())
//// |> query.where(query.eq(users.email(), email))
//// |> query.order_by(users.id(), query.Desc)
//// |> query.limit(20)
//// |> query.select({
////   use id <- query.field(users.id())
////   use email <- query.field(users.email())
////   query.done(User(id:, email:))
//// })
//// |> query.to_statement
//// |> pool.all(db, _)
//// ```
////
//// `to_statement` makes an ordinary `sql.Statement`, which runs with any
//// driver and can be labelled with `sql.label`. Names are quoted and
//// placeholders written when a driver renders it, for its own database.
////
//// ## What the types check
////
//// Every expression has the table it reads from and the Gleam type of its
//// values: `users.email()` is a `Column(Users, String)`. So comparing it
//// with an `Int` doesn't compile, and neither does filtering, sorting or
//// selecting by a column of a table the query doesn't read. Values are
//// compared as Gleam values, `eq(users.email(), email)`, and `eq` with
//// `None` is `IS NULL`.
////
//// A join reads from `Joined(a, b)`. Lift each column into it with `left`
//// or `right`, or, after a `left_join`, with `maybe`, which reads the
//// joined table's columns as `Option`s since rows with no match have none:
////
//// ```gleam
//// query.from(users.table())
//// |> query.left_join(
////   posts.table(),
////   on: query.same(query.right(posts.user_id()), query.left(users.id())),
//// )
//// |> query.select({
////   use email <- query.field(query.left(users.email()))
////   use title <- query.field(query.maybe(posts.title()))
////   query.done(#(email, title))
//// })
//// ```
////
//// A subquery is a query of its own, on its own tables, so it can't read
//// the outer query's columns.
////
//// ## Writes
////
//// `insert`, `update` and `delete` make the other statements, with
//// `set` for each column's value. On a write, `select` asks for the written
//// rows back with `RETURNING`, which Postgres and SQLite support and MySQL
//// does not.
////
//// ```gleam
//// query.update(users.table(), [query.set(users.bio(), None)])
//// |> query.where(query.eq(users.id(), id))
//// |> query.to_statement
//// |> pool.exec(db, _)
//// ```
////
//// ## Selected values
////
//// `field` reads a value. To read it, the selection calls the rest of
//// itself once with a placeholder value (`0`, `""`, `None`), so the rest
//// must select the same values whatever it is given: decide what to select
//// before the selection, not inside it.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import gloss/sql.{type Statement, type Value}

// --- Tables and columns ------------------------------------------------------

/// A table. `table` is a type of your own naming it, so that columns, and
/// the queries they are selected from, belong to one table.
pub opaque type Table(table) {
  Table(name: String)
}

/// The table called `name`, which may be qualified: `"audit.events"`.
pub fn table(name: String) -> Table(table) {
  Table(name)
}

/// An SQL expression on `table` whose values are `t` in Gleam. `kind` tells
/// columns, which `set` can write, from other expressions: use the
/// `Column` and `Expr` names for it.
pub opaque type Term(kind, table, t) {
  Term(
    node: Node,
    decoder: Decoder(t),
    /// Any value of the type; see "Selected values" above.
    zero: t,
    encode: fn(t) -> Value,
  )
}

pub type IsColumn

pub type IsExpr

/// A column of `table`.
pub type Column(table, t) =
  Term(IsColumn, table, t)

/// A computed value on `table`, such as a condition or a count.
pub type Expr(table, t) =
  Term(IsExpr, table, t)

/// The column `name` of `table`, of a type the other column functions don't
/// cover: read with `decoder`, written with `encode`. `zero` is any value of
/// the type, such as `0` or `""`; see "Selected values" above.
pub fn column(
  table: Table(table),
  name: String,
  decoder decoder: Decoder(t),
  zero zero: t,
  encode encode: fn(t) -> Value,
) -> Column(table, t) {
  Term(node: ColumnRef(table.name, name), decoder:, zero:, encode:)
}

pub fn int_column(table: Table(table), name: String) -> Column(table, Int) {
  column(table, name, decoder: decode.int, zero: 0, encode: sql.Int)
}

pub fn float_column(table: Table(table), name: String) -> Column(table, Float) {
  column(table, name, decoder: float_decoder(), zero: 0.0, encode: sql.Float)
}

pub fn text_column(table: Table(table), name: String) -> Column(table, String) {
  column(table, name, decoder: decode.string, zero: "", encode: sql.Text)
}

/// A boolean column, which MySQL and SQLite store as `0` or `1`.
pub fn bool_column(table: Table(table), name: String) -> Column(table, Bool) {
  column(table, name, decoder: bool_decoder(), zero: False, encode: sql.Bool)
}

pub fn bytes_column(
  table: Table(table),
  name: String,
) -> Column(table, BitArray) {
  column(table, name, decoder: decode.bit_array, zero: <<>>, encode: sql.Bytes)
}

pub fn timestamp_column(
  table: Table(table),
  name: String,
) -> Column(table, Timestamp) {
  column(
    table,
    name,
    decoder: sql.timestamp_decoder(),
    zero: timestamp.unix_epoch,
    encode: sql.Timestamp,
  )
}

pub fn date_column(
  table: Table(table),
  name: String,
) -> Column(table, calendar.Date) {
  column(
    table,
    name,
    decoder: sql.date_decoder(),
    zero: calendar.Date(1970, calendar.January, 1),
    encode: sql.Date,
  )
}

pub fn time_column(
  table: Table(table),
  name: String,
) -> Column(table, calendar.TimeOfDay) {
  column(
    table,
    name,
    decoder: sql.time_decoder(),
    zero: calendar.TimeOfDay(0, 0, 0, 0),
    encode: sql.Time,
  )
}

/// The value, allowing `NULL`, which reads and writes as `None`.
pub fn nullable(term: Term(kind, table, t)) -> Term(kind, table, Option(t)) {
  let Term(node:, decoder:, encode:, ..) = term
  Term(
    node:,
    decoder: decode.optional(decoder),
    zero: None,
    encode: sql.nullable(_, of: encode),
  )
}

/// A value of the first table of a join, read in the join.
pub fn left(term: Term(kind, a, t)) -> Term(kind, Joined(a, b), t) {
  let Term(node:, decoder:, zero:, encode:) = term
  Term(node:, decoder:, zero:, encode:)
}

/// A value of the table joined with `join`, read in the join, or of the
/// table joined with `left_join`, read in its `on` condition.
pub fn right(term: Term(kind, b, t)) -> Term(kind, Joined(a, b), t) {
  let Term(node:, decoder:, zero:, encode:) = term
  Term(node:, decoder:, zero:, encode:)
}

/// A value of the table joined with `left_join`, read in the join: `None`
/// in rows with no match.
pub fn maybe(
  term: Term(kind, b, t),
) -> Term(kind, Joined(a, Nullable(b)), Option(t)) {
  let Term(node:, decoder:, encode:, ..) = term
  Term(
    node:,
    decoder: decode.optional(decoder),
    zero: None,
    encode: sql.nullable(_, of: encode),
  )
}

fn float_decoder() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn bool_decoder() -> Decoder(Bool) {
  decode.one_of(decode.bool, [decode.int |> decode.map(fn(i) { i != 0 })])
}

// --- Expressions -------------------------------------------------------------

type Node {
  ColumnRef(table: String, name: String)
  Param(Value)
  /// SQL text with `?` for each argument.
  Raw(sql: String, args: List(Value))
  Keyword(String)
  Binary(left: Node, operator: String, right: Node)
  IsNull(Node, negated: Bool)
  Not(Node)
  Junction(operator: String, parts: List(Node))
  InList(Node, List(Node), negated: Bool)
  InQuery(Node, Body, negated: Bool)
  Exists(Body)
  Call(name: String, args: List(Node))
}

fn condition(node: Node) -> Expr(table, Bool) {
  Term(node:, decoder: bool_decoder(), zero: False, encode: sql.Bool)
}

fn whole_number(node: Node) -> Expr(table, Int) {
  Term(node:, decoder: decode.int, zero: 0, encode: sql.Int)
}

/// SQL text with a `?` for each of `args`, in order; write `??` for a `?`
/// that isn't one. The text is sent as it is: never build it from user
/// input.
///
/// Panics when the number of `?` and of `args` differ.
pub fn raw(sql: String, args: List(Value)) -> Expr(table, Bool) {
  let count = count_placeholders(<<sql:utf8>>, 0)
  case count == list.length(args) {
    True -> condition(Raw(sql, args))
    False ->
      panic as {
        "query.raw: \""
        <> sql
        <> "\" has "
        <> int.to_string(count)
        <> " placeholders but "
        <> int.to_string(list.length(args))
        <> " arguments"
      }
  }
}

fn count_placeholders(sql: BitArray, count: Int) -> Int {
  case sql {
    <<"??":utf8, rest:bytes>> -> count_placeholders(rest, count)
    <<"?":utf8, rest:bytes>> -> count_placeholders(rest, count + 1)
    <<_, rest:bytes>> -> count_placeholders(rest, count)
    _ -> count
  }
}

/// Whether `term` is `value`. With `None`, whether it is `NULL`.
pub fn eq(term: Term(kind, table, t), value: t) -> Expr(table, Bool) {
  case term.encode(value) {
    sql.Null -> condition(IsNull(term.node, negated: False))
    value -> condition(Binary(term.node, "=", Param(value)))
  }
}

/// Whether `term` isn't `value`. With `None`, whether it isn't `NULL`.
pub fn not_eq(term: Term(kind, table, t), value: t) -> Expr(table, Bool) {
  case term.encode(value) {
    sql.Null -> condition(IsNull(term.node, negated: True))
    value -> condition(Binary(term.node, "<>", Param(value)))
  }
}

pub fn lt(term: Term(kind, table, t), value: t) -> Expr(table, Bool) {
  compare_value(term, "<", value)
}

pub fn lte(term: Term(kind, table, t), value: t) -> Expr(table, Bool) {
  compare_value(term, "<=", value)
}

pub fn gt(term: Term(kind, table, t), value: t) -> Expr(table, Bool) {
  compare_value(term, ">", value)
}

pub fn gte(term: Term(kind, table, t), value: t) -> Expr(table, Bool) {
  compare_value(term, ">=", value)
}

/// `LIKE`, with `%` and `_` as wildcards.
pub fn like(
  term: Term(kind, table, String),
  pattern: String,
) -> Expr(table, Bool) {
  compare_value(term, "LIKE", pattern)
}

fn compare_value(
  term: Term(kind, table, t),
  operator: String,
  value: t,
) -> Expr(table, Bool) {
  condition(Binary(term.node, operator, Param(term.encode(value))))
}

/// How `compare` compares two values.
pub type Comparison {
  Equal
  NotEqual
  Less
  LessOrEqual
  Greater
  GreaterOrEqual
}

/// Compare two values of the query, such as the columns of a join.
pub fn compare(
  left: Term(a, table, t),
  comparison: Comparison,
  right: Term(b, table, t),
) -> Expr(table, Bool) {
  let operator = case comparison {
    Equal -> "="
    NotEqual -> "<>"
    Less -> "<"
    LessOrEqual -> "<="
    Greater -> ">"
    GreaterOrEqual -> ">="
  }
  condition(Binary(left.node, operator, right.node))
}

/// Whether two values of the query are equal: `compare(left, Equal, right)`.
pub fn same(
  left: Term(a, table, t),
  right: Term(b, table, t),
) -> Expr(table, Bool) {
  compare(left, Equal, right)
}

/// Whether `term` is one of `values`; never, when there are none.
pub fn in(term: Term(kind, table, t), values: List(t)) -> Expr(table, Bool) {
  in_values(term, values, negated: False, when_empty: "FALSE")
}

/// Whether `term` is none of `values`; always, when there are none.
pub fn not_in(
  term: Term(kind, table, t),
  values: List(t),
) -> Expr(table, Bool) {
  in_values(term, values, negated: True, when_empty: "TRUE")
}

fn in_values(
  term: Term(kind, table, t),
  values: List(t),
  negated negated: Bool,
  when_empty constant: String,
) -> Expr(table, Bool) {
  case values {
    [] -> condition(Keyword(constant))
    _ -> {
      let params = list.map(values, fn(value) { Param(term.encode(value)) })
      condition(InList(term.node, params, negated:))
    }
  }
}

/// Whether `term` is one of the values `query` selects.
pub fn in_query(
  term: Term(kind, table, t),
  query: Query(Filtered(Select), inner, t),
) -> Expr(table, Bool) {
  condition(InQuery(term.node, query.body, negated: False))
}

/// Whether `query` selects any row.
pub fn exists(query: Query(Filtered(Select), inner, row)) -> Expr(table, Bool) {
  condition(Exists(query.body))
}

/// All of `conditions`; true when there are none.
pub fn and(conditions: List(Term(kind, table, Bool))) -> Expr(table, Bool) {
  junction("AND", conditions, "TRUE")
}

/// Any of `conditions`; false when there are none.
pub fn or(conditions: List(Term(kind, table, Bool))) -> Expr(table, Bool) {
  junction("OR", conditions, "FALSE")
}

fn junction(
  operator: String,
  conditions: List(Term(kind, table, Bool)),
  identity: String,
) -> Expr(table, Bool) {
  case conditions {
    [] -> condition(Keyword(identity))
    [only] -> condition(only.node)
    _ -> condition(Junction(operator, list.map(conditions, node)))
  }
}

pub fn not(term: Term(kind, table, Bool)) -> Expr(table, Bool) {
  condition(Not(term.node))
}

/// `count(*)`.
pub fn count_all() -> Expr(table, Int) {
  whole_number(Call("count", [Keyword("*")]))
}

/// How many rows have a value that isn't `NULL`.
pub fn count(term: Term(kind, table, t)) -> Expr(table, Int) {
  whole_number(Call("count", [term.node]))
}

fn node(term: Term(kind, table, t)) -> Node {
  term.node
}

// --- Queries -----------------------------------------------------------------

/// What a query does: `Filtered(Select)`, `Insert`, `Filtered(Update)` or
/// `Filtered(Delete)`. Only filtered queries take `where`.
pub type Select

pub type Insert

pub type Update

pub type Delete

pub type Filtered(kind)

/// The tables of a join.
pub type Joined(left, right)

/// A table joined with `left_join`, whose columns are `NULL` in rows with
/// no match.
pub type Nullable(table)

/// A query of `kind` on `table`, whose rows decode as `row`.
pub opaque type Query(kind, table, row) {
  Query(body: Body, decoder: Decoder(row))
}

type Body {
  SelectBody(Clauses)
  InsertBody(
    into: String,
    rows: List(List(#(String, Node))),
    returning: List(Node),
  )
  UpdateBody(
    table: String,
    assignments: List(#(String, Node)),
    where: Option(Node),
    returning: List(Node),
  )
  DeleteBody(from: String, where: Option(Node), returning: List(Node))
}

/// A select's clauses.
type Clauses {
  Clauses(
    from: String,
    joins: List(Join),
    columns: List(Node),
    distinct: Bool,
    where: Option(Node),
    group_by: List(Node),
    having: Option(Node),
    order_by: List(#(Node, Direction)),
    limit: Option(Int),
    offset: Option(Int),
  )
}

type Join {
  Join(keyword: String, table: String, on: Node)
}

pub type Direction {
  Asc
  Desc
}

/// A column's new value, for `insert` and `update`.
pub opaque type Assignment(table) {
  Assignment(column: String, value: Node)
}

pub fn set(column: Column(table, t), value: t) -> Assignment(table) {
  let assert ColumnRef(name:, ..) = column.node
  Assignment(name, Param(column.encode(value)))
}

/// Select every column of `table`. Rows decode as `Dynamic` until `select`
/// chooses columns.
pub fn from(table: Table(table)) -> Query(Filtered(Select), table, Dynamic) {
  Query(
    body: SelectBody(Clauses(
      from: table.name,
      joins: [],
      columns: [],
      distinct: False,
      where: None,
      group_by: [],
      having: None,
      order_by: [],
      limit: None,
      offset: None,
    )),
    decoder: decode.dynamic,
  )
}

/// Insert one row. Columns left out get their default.
pub fn insert(
  into table: Table(table),
  row row: List(Assignment(table)),
) -> Query(Insert, table, Dynamic) {
  insert_rows(table, [row])
}

/// Insert several rows in one statement. A column given in some rows but
/// not others gets its default in the others, which SQLite can't do: give
/// every row the same columns there. No rows inserts nothing.
pub fn insert_rows(
  into table: Table(table),
  rows rows: List(List(Assignment(table))),
) -> Query(Insert, table, Dynamic) {
  let rows =
    list.map(
      rows,
      list.map(_, fn(assignment: Assignment(table)) {
        #(assignment.column, assignment.value)
      }),
    )
  Query(
    body: InsertBody(into: table.name, rows:, returning: []),
    decoder: decode.dynamic,
  )
}

/// Update every row of `table`, or those `where` chooses. No assignments
/// updates nothing.
pub fn update(
  table: Table(table),
  set assignments: List(Assignment(table)),
) -> Query(Filtered(Update), table, Dynamic) {
  let assignments =
    list.map(assignments, fn(assignment) {
      #(assignment.column, assignment.value)
    })
  Query(
    body: UpdateBody(
      table: table.name,
      assignments:,
      where: None,
      returning: [],
    ),
    decoder: decode.dynamic,
  )
}

/// Delete every row of `table`, or those `where` chooses.
pub fn delete(
  from table: Table(table),
) -> Query(Filtered(Delete), table, Dynamic) {
  Query(
    body: DeleteBody(from: table.name, where: None, returning: []),
    decoder: decode.dynamic,
  )
}

/// Only rows that meet `condition`. Each `where` adds a condition that must
/// also hold.
pub fn where(
  query: Query(Filtered(kind), table, row),
  condition: Term(c, table, Bool),
) -> Query(Filtered(kind), table, row) {
  let add = fn(existing) {
    case existing {
      None -> Some(condition.node)
      Some(node) -> Some(Junction("AND", [node, condition.node]))
    }
  }
  let body = case query.body {
    SelectBody(clauses) ->
      SelectBody(Clauses(..clauses, where: add(clauses.where)))
    UpdateBody(where:, ..) as body -> UpdateBody(..body, where: add(where))
    DeleteBody(where:, ..) as body -> DeleteBody(..body, where: add(where))
    InsertBody(..) as body -> body
  }
  Query(..query, body:)
}

/// Join `table` on `on`, keeping only rows that match. Read the query's
/// columns with `left` and `table`'s with `right`.
pub fn join(
  query: Query(Filtered(Select), a, row),
  table: Table(b),
  on condition: Term(c, Joined(a, b), Bool),
) -> Query(Filtered(Select), Joined(a, b), row) {
  add_join(query, "JOIN", table, condition)
}

/// Join `table` on `on`, keeping rows with no match, whose `table` columns
/// are then `NULL`. In `on`, read the query's columns with `left` and
/// `table`'s with `right`; after it, read `table`'s with `maybe`.
pub fn left_join(
  query: Query(Filtered(Select), a, row),
  table: Table(b),
  on condition: Term(c, Joined(a, b), Bool),
) -> Query(Filtered(Select), Joined(a, Nullable(b)), row) {
  add_join(query, "LEFT JOIN", table, condition)
}

fn add_join(
  query: Query(Filtered(Select), a, row),
  keyword: String,
  table: Table(b),
  condition: Term(c, Joined(a, b), Bool),
) -> Query(Filtered(Select), joined, row) {
  let join = Join(keyword:, table: table.name, on: condition.node)
  let Query(body:, decoder:) =
    map_select(query, fn(clauses) {
      Clauses(..clauses, joins: list.append(clauses.joins, [join]))
    })
  Query(body:, decoder:)
}

/// Sort by `by`. Each `order_by` sorts ties of the ones before.
pub fn order_by(
  query: Query(Filtered(Select), table, row),
  by term: Term(kind, table, t),
  direction direction: Direction,
) -> Query(Filtered(Select), table, row) {
  map_select(query, fn(body) {
    Clauses(
      ..body,
      order_by: list.append(body.order_by, [#(term.node, direction)]),
    )
  })
}

pub fn group_by(
  query: Query(Filtered(Select), table, row),
  term: Term(kind, table, t),
) -> Query(Filtered(Select), table, row) {
  map_select(query, fn(body) {
    Clauses(..body, group_by: list.append(body.group_by, [term.node]))
  })
}

/// Only groups that meet `condition`.
pub fn having(
  query: Query(Filtered(Select), table, row),
  condition: Term(kind, table, Bool),
) -> Query(Filtered(Select), table, row) {
  map_select(query, fn(body) {
    let having = case body.having {
      None -> condition.node
      Some(node) -> Junction("AND", [node, condition.node])
    }
    Clauses(..body, having: Some(having))
  })
}

pub fn limit(
  query: Query(Filtered(Select), table, row),
  count: Int,
) -> Query(Filtered(Select), table, row) {
  map_select(query, fn(body) { Clauses(..body, limit: Some(count)) })
}

/// Skip the first `count` rows.
pub fn offset(
  query: Query(Filtered(Select), table, row),
  count: Int,
) -> Query(Filtered(Select), table, row) {
  map_select(query, fn(body) { Clauses(..body, offset: Some(count)) })
}

/// Drop duplicate rows.
pub fn distinct(
  query: Query(Filtered(Select), table, row),
) -> Query(Filtered(Select), table, row) {
  map_select(query, fn(body) { Clauses(..body, distinct: True) })
}

/// Change the query with `apply` when there is a value: an optional filter.
///
/// ```gleam
/// query.from(users.table())
/// |> query.when(search, fn(q, search) {
///   query.where(q, query.like(users.email(), "%" <> search <> "%"))
/// })
/// ```
pub fn when(
  query: Query(kind, table, row),
  value: Option(v),
  apply: fn(Query(kind, table, row), v) -> Query(kind, table, row),
) -> Query(kind, table, row) {
  case value {
    Some(value) -> apply(query, value)
    None -> query
  }
}

fn map_select(
  query: Query(kind, table, row),
  change: fn(Clauses) -> Clauses,
) -> Query(kind, table, row) {
  case query.body {
    SelectBody(clauses) -> Query(..query, body: SelectBody(change(clauses)))
    _ -> query
  }
}

// --- Selections --------------------------------------------------------------

/// The values a query selects, and how they make a row.
pub opaque type Selection(table, row) {
  Selection(
    columns: fn() -> List(Node),
    /// The row's decoder, given the position of the first column.
    decoder: fn(Int) -> Decoder(row),
  )
}

/// Select `selection`'s values. On an insert, update or delete, they are
/// the written rows' values, returned with `RETURNING`.
pub fn select(
  query: Query(kind, table, ignored),
  selection: Selection(table, row),
) -> Query(kind, table, row) {
  let columns = selection.columns()
  let body = case query.body {
    SelectBody(clauses) -> SelectBody(Clauses(..clauses, columns:))
    InsertBody(..) as body -> InsertBody(..body, returning: columns)
    UpdateBody(..) as body -> UpdateBody(..body, returning: columns)
    DeleteBody(..) as body -> DeleteBody(..body, returning: columns)
  }
  Query(body:, decoder: selection.decoder(0))
}

/// Select `term`, then the rest.
pub fn field(
  term: Term(kind, table, t),
  next: fn(t) -> Selection(table, row),
) -> Selection(table, row) {
  Selection(
    columns: fn() { [term.node, ..{ next(term.zero).columns }()] },
    decoder: fn(position) {
      decode.field(position, term.decoder, fn(value) {
        next(value).decoder(position + 1)
      })
    },
  )
}

/// The row made from the selected values.
pub fn done(row: row) -> Selection(table, row) {
  Selection(columns: fn() { [] }, decoder: fn(_) { decode.success(row) })
}

/// Select only `term`, so each row is its value: for a count, or for a
/// subquery with `in_query`.
pub fn only(term: Term(kind, table, t)) -> Selection(table, t) {
  field(term, done)
}

// --- Compiling ---------------------------------------------------------------

/// The statement that runs the query, decoding rows as its selection says.
pub fn to_statement(query: Query(kind, table, row)) -> Statement(row) {
  sql.query("")
  |> body(query.body)
  |> sql.returning(query.decoder)
}

/// An `OFFSET` needs a `LIMIT` in MySQL and SQLite; this one is as good as
/// none, and exact on JavaScript.
const no_limit = 9_007_199_254_740_991

/// Runs and does nothing, for writes with nothing to write.
const nothing = "SELECT 1 WHERE 1 = 0"

fn body(s: Statement(Dynamic), body: Body) -> Statement(Dynamic) {
  case body {
    SelectBody(clauses) -> select_body(s, clauses)
    InsertBody(rows: [], ..) | UpdateBody(assignments: [], ..) ->
      sql.append(s, nothing)
    InsertBody(into:, rows:, returning:) ->
      insert_body(s, into, rows) |> returning_clause(returning)
    UpdateBody(table:, assignments:, where:, returning:) ->
      s
      |> sql.append("UPDATE ")
      |> sql.identifier(table)
      |> sql.append(" SET ")
      |> separated(assignments, ", ", fn(s, assignment) {
        let #(column, value) = assignment
        s
        |> sql.identifier(column)
        |> sql.append(" = ")
        |> expr(value)
      })
      |> where_clause(where)
      |> returning_clause(returning)
    DeleteBody(from:, where:, returning:) ->
      s
      |> sql.append("DELETE FROM ")
      |> sql.identifier(from)
      |> where_clause(where)
      |> returning_clause(returning)
  }
}

fn select_body(s: Statement(Dynamic), clauses: Clauses) -> Statement(Dynamic) {
  let Clauses(
    from:,
    joins:,
    columns:,
    distinct:,
    where:,
    group_by:,
    having:,
    order_by:,
    limit:,
    offset:,
  ) = clauses
  let s = sql.append(s, "SELECT ")
  let s = case distinct {
    True -> sql.append(s, "DISTINCT ")
    False -> s
  }
  let s = case columns {
    [] -> sql.append(s, "*")
    _ -> separated(s, columns, ", ", expr)
  }
  let s =
    s
    |> sql.append(" FROM ")
    |> sql.identifier(from)
    |> list.fold(joins, _, fn(s, join) {
      s
      |> sql.append(" " <> join.keyword <> " ")
      |> sql.identifier(join.table)
      |> sql.append(" ON ")
      |> expr(join.on)
    })
    |> where_clause(where)
  let s = case group_by {
    [] -> s
    _ -> s |> sql.append(" GROUP BY ") |> separated(group_by, ", ", expr)
  }
  let s = case having {
    None -> s
    Some(condition) -> s |> sql.append(" HAVING ") |> expr(condition)
  }
  let s = case order_by {
    [] -> s
    _ ->
      s
      |> sql.append(" ORDER BY ")
      |> separated(order_by, ", ", fn(s, order) {
        let #(by, direction) = order
        expr(s, by)
        |> sql.append(case direction {
          Asc -> " ASC"
          Desc -> " DESC"
        })
      })
  }
  case limit, offset {
    None, None -> s
    Some(limit), None -> s |> sql.append(" LIMIT ") |> sql.arg(sql.Int(limit))
    limit, Some(offset) ->
      s
      |> sql.append(" LIMIT ")
      |> sql.arg(sql.Int(option.unwrap(limit, no_limit)))
      |> sql.append(" OFFSET ")
      |> sql.arg(sql.Int(offset))
  }
}

fn insert_body(
  s: Statement(Dynamic),
  into: String,
  rows: List(List(#(String, Node))),
) -> Statement(Dynamic) {
  let s = s |> sql.append("INSERT INTO ") |> sql.identifier(into)
  // Every column any row sets, in the order they first appear.
  let columns =
    list.fold(rows, [], fn(seen, row) {
      list.fold(row, seen, fn(seen, assignment) {
        case list.contains(seen, assignment.0) {
          True -> seen
          False -> [assignment.0, ..seen]
        }
      })
    })
    |> list.reverse
  case columns {
    [] -> sql.append(s, " DEFAULT VALUES")
    _ ->
      s
      |> sql.append(" (")
      |> separated(columns, ", ", sql.identifier)
      |> sql.append(") VALUES ")
      |> separated(rows, ", ", fn(s, row) {
        s
        |> sql.append("(")
        |> separated(columns, ", ", fn(s, column) {
          case list.key_find(row, column) {
            Ok(value) -> expr(s, value)
            Error(Nil) -> sql.append(s, "DEFAULT")
          }
        })
        |> sql.append(")")
      })
  }
}

fn where_clause(
  s: Statement(Dynamic),
  where: Option(Node),
) -> Statement(Dynamic) {
  case where {
    None -> s
    Some(condition) -> s |> sql.append(" WHERE ") |> expr(condition)
  }
}

fn returning_clause(
  s: Statement(Dynamic),
  columns: List(Node),
) -> Statement(Dynamic) {
  case columns {
    [] -> s
    _ -> s |> sql.append(" RETURNING ") |> separated(columns, ", ", expr)
  }
}

fn expr(s: Statement(Dynamic), node: Node) -> Statement(Dynamic) {
  case node {
    ColumnRef(table:, name:) -> sql.identifier(s, table <> "." <> name)
    Param(sql.Null) -> sql.append(s, "NULL")
    Param(value) -> sql.arg(s, value)
    Raw(sql:, args:) -> raw_text(s, <<sql:utf8>>, <<>>, args)
    Keyword(keyword) -> sql.append(s, keyword)
    Binary(left:, operator:, right:) ->
      s
      |> sql.append("(")
      |> expr(left)
      |> sql.append(" " <> operator <> " ")
      |> expr(right)
      |> sql.append(")")
    IsNull(node, negated:) ->
      s
      |> sql.append("(")
      |> expr(node)
      |> sql.append(case negated {
        True -> " IS NOT NULL)"
        False -> " IS NULL)"
      })
    Not(node) -> s |> sql.append("(NOT ") |> expr(node) |> sql.append(")")
    Junction(operator:, parts:) ->
      s
      |> sql.append("(")
      |> separated(parts, " " <> operator <> " ", expr)
      |> sql.append(")")
    InList(node, values, negated:) ->
      s
      |> sql.append("(")
      |> expr(node)
      |> sql.append(in_keyword(negated))
      |> separated(values, ", ", expr)
      |> sql.append("))")
    InQuery(node, query, negated:) ->
      s
      |> sql.append("(")
      |> expr(node)
      |> sql.append(in_keyword(negated))
      |> body(query)
      |> sql.append("))")
    Exists(query) ->
      s |> sql.append("EXISTS (") |> body(query) |> sql.append(")")
    Call(name:, args:) ->
      s
      |> sql.append(name <> "(")
      |> separated(args, ", ", expr)
      |> sql.append(")")
  }
}

fn in_keyword(negated: Bool) -> String {
  case negated {
    True -> " NOT IN ("
    False -> " IN ("
  }
}

/// Raw text up to each `?`, then its argument; `??` is a literal `?`.
fn raw_text(
  s: Statement(Dynamic),
  sql: BitArray,
  run: BitArray,
  args: List(Value),
) -> Statement(Dynamic) {
  case sql, args {
    <<"??":utf8, rest:bytes>>, _ ->
      raw_text(s, rest, <<run:bits, "?":utf8>>, args)
    <<"?":utf8, rest:bytes>>, [arg, ..args] ->
      s
      |> sql.append(text_of(run))
      |> sql.arg(arg)
      |> raw_text(rest, <<>>, args)
    <<c, rest:bytes>>, _ -> raw_text(s, rest, <<run:bits, c>>, args)
    _, _ -> sql.append(s, text_of(run))
  }
}

fn text_of(bytes: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

fn separated(
  s: Statement(Dynamic),
  items: List(a),
  separator: String,
  add: fn(Statement(Dynamic), a) -> Statement(Dynamic),
) -> Statement(Dynamic) {
  case items {
    [] -> s
    [item] -> add(s, item)
    [item, ..rest] ->
      add(s, item)
      |> sql.append(separator)
      |> separated(rest, separator, add)
  }
}

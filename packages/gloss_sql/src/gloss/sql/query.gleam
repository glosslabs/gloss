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
////   query.column(table(), "id", decode.int, 0)
//// }
////
//// pub fn email() -> query.Column(Users, String) {
////   query.column(table(), "email", decode.string, "")
//// }
////
//// pub fn bio() -> query.Column(Users, Option(String)) {
////   query.column(table(), "bio", decode.string, "") |> query.nullable
//// }
//// ```
////
//// Then build queries from them. Expressions carry the Gleam type of their
//// values, so comparing `email` with an `Int` doesn't compile, and the
//// selected columns decode into a row as `gleam/dynamic/decode` would:
////
//// ```gleam
//// query.from(users.table())
//// |> query.where(query.eq(query.ref(users.email()), query.text(email)))
//// |> query.order_by(query.ref(users.id()), query.Desc)
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
//// ## Without a schema
////
//// `table` and `named` take plain names, and their types fit anything, so
//// a query can also be built from strings. `columns` selects expressions
//// whose rows decode as `Dynamic`, by position.
////
//// ## Writes
////
//// `insert`, `update` and `delete` make the other statements, with
//// `set` for each column's value. On a write, `select` asks for the written
//// rows back with `RETURNING`, which Postgres and SQLite support and MySQL
//// does not.
////
//// ```gleam
//// query.update(users.table(), [query.set(users.bio(), query.null())])
//// |> query.where(query.eq(query.ref(users.id()), query.int(id)))
//// |> query.to_statement
//// |> pool.exec(db, _)
//// ```
////
//// ## Selected values
////
//// `field` reads a column. To read it, the selection calls the rest of
//// itself once with the column's `zero` value, so the rest must select the
//// same columns whatever value it is given: decide which columns to select
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

/// A column of `table` whose values are `t` in Gleam: read with `decoder`.
pub opaque type Column(table, t) {
  Column(table: String, name: String, decoder: Decoder(t), zero: t)
}

/// The column `name` of `table`, decoded with `decoder`. `zero` is any
/// value of its type, such as `0` or `""`; see "Selected values" above.
pub fn column(
  table: Table(table),
  name: String,
  decoder: Decoder(t),
  zero: t,
) -> Column(table, t) {
  Column(table: table.name, name:, decoder:, zero:)
}

/// The column, allowing `NULL`, which reads as `None`.
pub fn nullable(column: Column(table, t)) -> Column(table, Option(t)) {
  let Column(table:, name:, decoder:, ..) = column
  Column(table:, name:, decoder: decode.optional(decoder), zero: None)
}

/// A column of the first table of a join, selected from the join.
pub fn left(column: Column(a, t)) -> Column(Joined(a, b), t) {
  let Column(table:, name:, decoder:, zero:) = column
  Column(table:, name:, decoder:, zero:)
}

/// A column of the joined table, selected from the join. After a
/// `left_join`, its values may be `NULL`: make it `nullable` too.
pub fn right(column: Column(b, t)) -> Column(Joined(a, b), t) {
  let Column(table:, name:, decoder:, zero:) = column
  Column(table:, name:, decoder:, zero:)
}

// --- Expressions -------------------------------------------------------------

/// An SQL expression whose values are `t` in Gleam.
pub opaque type Expr(t) {
  Expr(node: Node)
}

type Node {
  ColumnRef(table: String, name: String)
  Name(String)
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

/// The column's value.
pub fn ref(column: Column(table, t)) -> Expr(t) {
  Expr(ColumnRef(column.table, column.name))
}

/// The column, or other name, called `name`, of any type: `named("email")`
/// or `named("users.email")`.
pub fn named(name: String) -> Expr(t) {
  Expr(Name(name))
}

pub fn int(value: Int) -> Expr(Int) {
  Expr(Param(sql.Int(value)))
}

pub fn float(value: Float) -> Expr(Float) {
  Expr(Param(sql.Float(value)))
}

pub fn text(value: String) -> Expr(String) {
  Expr(Param(sql.Text(value)))
}

pub fn bool(value: Bool) -> Expr(Bool) {
  Expr(Param(sql.Bool(value)))
}

pub fn bytes(value: BitArray) -> Expr(BitArray) {
  Expr(Param(sql.Bytes(value)))
}

pub fn timestamp(value: Timestamp) -> Expr(Timestamp) {
  Expr(Param(sql.Timestamp(value)))
}

pub fn date(value: calendar.Date) -> Expr(calendar.Date) {
  Expr(Param(sql.Date(value)))
}

pub fn time(value: calendar.TimeOfDay) -> Expr(calendar.TimeOfDay) {
  Expr(Param(sql.Time(value)))
}

/// An argument of any type, for values the functions above don't cover.
pub fn value(value: Value) -> Expr(t) {
  Expr(Param(value))
}

/// `NULL`.
pub fn null() -> Expr(Option(t)) {
  Expr(Keyword("NULL"))
}

/// A value for a nullable column: `eq(ref(users.bio()), some(text("hi")))`.
pub fn some(expr: Expr(t)) -> Expr(Option(t)) {
  Expr(expr.node)
}

/// SQL text with a `?` for each of `args`, in order; write `??` for a `?`
/// that isn't one. The text is sent as it is: never build it from user
/// input.
///
/// Panics when the number of `?` and of `args` differ.
pub fn raw(sql: String, args: List(Value)) -> Expr(t) {
  let count = count_placeholders(<<sql:utf8>>, 0)
  case count == list.length(args) {
    True -> Expr(Raw(sql, args))
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

pub fn eq(left: Expr(t), right: Expr(t)) -> Expr(Bool) {
  binary(left, "=", right)
}

pub fn not_eq(left: Expr(t), right: Expr(t)) -> Expr(Bool) {
  binary(left, "<>", right)
}

pub fn lt(left: Expr(t), right: Expr(t)) -> Expr(Bool) {
  binary(left, "<", right)
}

pub fn lte(left: Expr(t), right: Expr(t)) -> Expr(Bool) {
  binary(left, "<=", right)
}

pub fn gt(left: Expr(t), right: Expr(t)) -> Expr(Bool) {
  binary(left, ">", right)
}

pub fn gte(left: Expr(t), right: Expr(t)) -> Expr(Bool) {
  binary(left, ">=", right)
}

/// `LIKE`, with `%` and `_` as wildcards.
pub fn like(value: Expr(String), pattern: Expr(String)) -> Expr(Bool) {
  binary(value, "LIKE", pattern)
}

fn binary(left: Expr(a), operator: String, right: Expr(a)) -> Expr(b) {
  Expr(Binary(left.node, operator, right.node))
}

pub fn is_null(expr: Expr(Option(t))) -> Expr(Bool) {
  Expr(IsNull(expr.node, negated: False))
}

pub fn is_not_null(expr: Expr(Option(t))) -> Expr(Bool) {
  Expr(IsNull(expr.node, negated: True))
}

/// Whether the value is one of `values`; never, when there are none.
pub fn in(expr: Expr(t), values: List(Expr(t))) -> Expr(Bool) {
  case values {
    [] -> Expr(Keyword("FALSE"))
    _ -> Expr(InList(expr.node, list.map(values, node), negated: False))
  }
}

/// Whether the value is none of `values`; always, when there are none.
pub fn not_in(expr: Expr(t), values: List(Expr(t))) -> Expr(Bool) {
  case values {
    [] -> Expr(Keyword("TRUE"))
    _ -> Expr(InList(expr.node, list.map(values, node), negated: True))
  }
}

/// Whether the value is one of the rows `query` selects.
pub fn in_query(
  expr: Expr(t),
  query: Query(Filtered(Select), table, t),
) -> Expr(Bool) {
  Expr(InQuery(expr.node, query.body, negated: False))
}

/// Whether `query` selects any row.
pub fn exists(query: Query(Filtered(Select), table, row)) -> Expr(Bool) {
  Expr(Exists(query.body))
}

/// All of `conditions`; true when there are none.
pub fn and(conditions: List(Expr(Bool))) -> Expr(Bool) {
  junction("AND", conditions, "TRUE")
}

/// Any of `conditions`; false when there are none.
pub fn or(conditions: List(Expr(Bool))) -> Expr(Bool) {
  junction("OR", conditions, "FALSE")
}

fn junction(
  operator: String,
  conditions: List(Expr(Bool)),
  identity: String,
) -> Expr(Bool) {
  case conditions {
    [] -> Expr(Keyword(identity))
    [condition] -> condition
    _ -> Expr(Junction(operator, list.map(conditions, node)))
  }
}

pub fn not(condition: Expr(Bool)) -> Expr(Bool) {
  Expr(Not(condition.node))
}

/// `count(*)`.
pub fn count_all() -> Expr(Int) {
  Expr(Call("count", [Keyword("*")]))
}

/// How many rows have a value that isn't `NULL`.
pub fn count(expr: Expr(t)) -> Expr(Int) {
  Expr(Call("count", [expr.node]))
}

fn node(expr: Expr(t)) -> Node {
  expr.node
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

pub fn set(column: Column(table, t), value: Expr(t)) -> Assignment(table) {
  Assignment(column.name, value.node)
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
  condition: Expr(Bool),
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

/// Join `table` on `on`, keeping only rows that match.
pub fn join(
  query: Query(Filtered(Select), a, row),
  table: Table(b),
  on condition: Expr(Bool),
) -> Query(Filtered(Select), Joined(a, b), row) {
  add_join(query, "JOIN", table, condition)
}

/// Join `table` on `on`, keeping rows with no match, whose `table` columns
/// are then `NULL`.
pub fn left_join(
  query: Query(Filtered(Select), a, row),
  table: Table(b),
  on condition: Expr(Bool),
) -> Query(Filtered(Select), Joined(a, b), row) {
  add_join(query, "LEFT JOIN", table, condition)
}

fn add_join(
  query: Query(Filtered(Select), a, row),
  keyword: String,
  table: Table(b),
  condition: Expr(Bool),
) -> Query(Filtered(Select), Joined(a, b), row) {
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
  by expr: Expr(t),
  direction direction: Direction,
) -> Query(Filtered(Select), table, row) {
  map_select(query, fn(body) {
    Clauses(
      ..body,
      order_by: list.append(body.order_by, [#(expr.node, direction)]),
    )
  })
}

pub fn group_by(
  query: Query(Filtered(Select), table, row),
  expr: Expr(t),
) -> Query(Filtered(Select), table, row) {
  map_select(query, fn(body) {
    Clauses(..body, group_by: list.append(body.group_by, [expr.node]))
  })
}

/// Only groups that meet `condition`.
pub fn having(
  query: Query(Filtered(Select), table, row),
  condition: Expr(Bool),
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

/// Select `column`, then the rest.
pub fn field(
  column: Column(table, t),
  next: fn(t) -> Selection(table, row),
) -> Selection(table, row) {
  expression(ref(column), column.decoder, column.zero, next)
}

/// Select a computed value, such as `count_all()`, read with `decoder`.
/// `zero` is any value of its type.
pub fn expression(
  expr: Expr(t),
  decoder: Decoder(t),
  zero: t,
  next: fn(t) -> Selection(table, row),
) -> Selection(table, row) {
  Selection(
    columns: fn() { [expr.node, ..{ next(zero).columns }()] },
    decoder: fn(position) {
      decode.field(position, decoder, fn(value) {
        next(value).decoder(position + 1)
      })
    },
  )
}

/// The row made from the selected values.
pub fn done(row: row) -> Selection(table, row) {
  Selection(columns: fn() { [] }, decoder: fn(_) { decode.success(row) })
}

/// Select `exprs`. Each row is `Dynamic`, its values read by position:
/// `decode.field(0, decode.int)`.
pub fn columns(exprs: List(Expr(t))) -> Selection(table, Dynamic) {
  let nodes = list.map(exprs, node)
  Selection(columns: fn() { nodes }, decoder: fn(_) { decode.dynamic })
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
    Name(name) -> sql.identifier(s, name)
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

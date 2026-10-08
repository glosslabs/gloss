# gloss_sql

SQL statements, values, errors and row decoders shared by every gloss
database driver, on the BEAM and in JavaScript. Imported as `gloss/sql`.

```gleam
import gleam/dynamic/decode
import gloss/sql

pub fn recent(limit: Int) -> sql.Statement(#(Int, String)) {
  sql.query("select id, title from threads order by id desc limit ")
  |> sql.arg(sql.Int(limit))
  |> sql.returning({
    use id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    decode.success(#(id, title))
  })
}

// On the BEAM:    pool.all(db, recent(20))
// In the browser: async.all(db, recent(20))
```

- `query`, `bind`, `append`, `arg` (writes the driver's placeholder), `identifier` (a quoted name), `when`, `returning`, `label`.
- `gloss/sql/query` builds statements from typed tables and columns instead of text:

```gleam
query.from(users.table())
|> query.where(query.eq(query.ref(users.email()), query.text(email)))
|> query.order_by(query.ref(users.id()), query.Desc)
|> query.select({
  use id <- query.field(users.id())
  use email <- query.field(users.email())
  query.done(User(id:, email:))
})
|> query.to_statement
```

  Selects with joins, grouping, subqueries and raw fragments; inserts, updates and deletes with `RETURNING`. Quoting and placeholders follow the driver's `Dialect` (Postgres, MySQL, SQLite).
- One `Error` type for every driver, with unique, foreign key, not-null and check violations broken out.
- `timestamp_decoder`, `date_decoder` and `time_decoder` for column values.

# gloss_sql

SQL statements, values, errors and row decoding shared by every gloss
database driver, on the BEAM and in JavaScript. Imported as `gloss/sql`.

A statement built here runs anywhere a gloss driver does: with
[`gloss/sql/pool`](../gloss) on the BEAM (Postgres, MySQL, SQLite), or with a
JavaScript driver in the browser (SQLite, PGlite). Queries and row decoders
can live in shared code used by both.

```gleam
import gleam/dynamic/decode
import gloss/sql

pub fn recent_threads(limit: Int) -> sql.Statement(Thread) {
  sql.query("select id, title from threads order by id desc limit ")
  |> sql.arg(sql.Int(limit))
  |> sql.returning({
    use id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    decode.success(Thread(id:, title:))
  })
  |> sql.label("threads.recent")
}

// On the BEAM:      pool.all(db, recent_threads(20))
// In the browser:   sqlite.all(db, recent_threads(20))  // a Promise
```

| | |
|---|---|
| `Value` | Arguments and column values: `Null`, `Bool`, `Int`, `Float`, `Text`, `Bytes`, `Timestamp`, `Date`, `Time`, `Array`; `nullable` for `Option`s |
| `Statement` | `query`, `bind`, `append`, `arg` (writes the driver's placeholder), `when`, `returning`, `label` |
| `Error` | One error type for every driver, with unique, foreign key, not-null and check violations broken out; `describe` |
| Decoders | `timestamp_decoder`, `date_decoder`, `time_decoder` |
| Transactions | `TransactionError` and `flatten` |
| For drivers | `render`, `name`, `Outcome`, and `all`/`optional`/`one` to decode an outcome |

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

- `query`, `bind`, `append`, `arg` (writes the driver's placeholder), `when`, `returning`, `label`.
- One `Error` type for every driver, with unique, foreign key, not-null and check violations broken out.
- `timestamp_decoder`, `date_decoder` and `time_decoder` for column values.

# gloss_sqlite

A SQLite driver for [`gloss/sql/pool`](../gloss) on the BEAM, built on the
[esqlite](https://hex.pm/packages/esqlite) NIF (a C compiler is needed the
first time it builds). Imported as `gloss/sqlite`.

```gleam
let assert Ok(db) = pool.new(sqlite.driver(sqlite.file("data/app.db"))) |> pool.start

sql.query("select email from users where id = ?1")
|> sql.bind(sql.Int(id))
|> sql.returning(decode.at([0], decode.string))
|> pool.one(db, _)
```

- `file(path)` uses write-ahead logging; `memory()` is shared by the pool's connections.
- Columns declared `BOOLEAN`, `TIMESTAMP`, `DATE`, `TIME` or `BLOB` read back as Gleam values.
- Values follow the same rules as [`gloss_sqlite_wasm`](../gloss_sqlite_wasm), so statements can be shared with the browser.

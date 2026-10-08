# gloss_sqlite

A SQLite driver for [`gloss/sql/pool`](../gloss) on the BEAM, imported as
`gloss/sqlite`. It is built on [esqlite](https://hex.pm/packages/esqlite),
an Erlang NIF that bundles SQLite, so a C compiler is needed the first time
it builds.

```gleam
import gloss/sql
import gloss/sql/pool
import gloss/sqlite

let assert Ok(db) = pool.new(sqlite.driver(sqlite.file("data/app.db"))) |> pool.start

sql.query("select id, email from users where id = ?1")
|> sql.bind(sql.Int(id))
|> sql.returning(user_decoder())
|> pool.one(db, _)
```

| | |
|---|---|
| `sqlite.file(path)` | A database file, created if missing, in write-ahead-log mode so readers don't block the writer |
| `sqlite.memory()` | A fresh in-memory database shared by the pool's connections; gone when the last one closes |
| `sqlite.driver(config)` | The driver for `pool.new` |

Every connection turns on foreign keys and waits up to five seconds for a
lock. SQLite allows one writer at a time, so a large pool only helps readers.
A statement that runs past the pool's query timeout is interrupted, fails
with `QueryTimeout`, and its connection is closed.

## Values

Placeholders are `?1`, `?2`, ..., which `sql.arg` writes for you.

| Gleam | Stored as | Read back as a Gleam value when the column is declared |
|---|---|---|
| `Bool` | 0 or 1 | `BOOLEAN` |
| `Int`, `Float`, `Text`, `Bytes` | integer, real, text, blob | always (`BLOB` for blobs that are valid UTF-8) |
| `Timestamp` | RFC 3339 text in UTC | `TIMESTAMP` or `DATETIME` (SQLite's `YYYY-MM-DD HH:MM:SS` and Unix seconds also read) |
| `Date` | `YYYY-MM-DD` | `DATE` |
| `Time` | `HH:MM:SS[.fffffffff]` | `TIME` |
| `Array` | refused: store JSON text instead | |

Constraint failures come back as `UniqueViolation`, `ForeignKeyViolation`,
`NotNullViolation` and `CheckViolation`, named like `users.email`.

The browser driver, [`gloss_sqlite_wasm`](../gloss_sqlite_wasm), follows the
same rules, so statements and decoders can be shared between the server and
the browser.

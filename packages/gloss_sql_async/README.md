# gloss_sql_async

Running [`gloss/sql`](../gloss_sql) statements in JavaScript, where every
call returns a `Promise`. Imported as `gloss/sql/async`, it is the browser's
counterpart to `gloss/sql/pool`: drivers such as
[`gloss_sqlite_wasm`](../gloss_sqlite_wasm) and [`gloss_pglite`](../gloss_pglite)
open a `Database`, and the same statements and decoders the server uses run
on it.

```gleam
import gleam/javascript/promise
import gloss/sql
import gloss/sql/async

use db <- promise.try_await(wasm.open(wasm.memory()))
sql.query("select id, title from notes order by id desc limit ?1")
|> sql.bind(sql.Int(20))
|> sql.returning(note_decoder())
|> async.all(db, _)
```

| | |
|---|---|
| `all`, `one`, `optional`, `exec` | Run a statement for its rows, its only row, an optional row, or the count of affected rows |
| `script` | Run SQL text holding several statements, such as a schema |
| `transaction` | Commit when the body resolves to `Ok`, roll back on `Error` or a rejection; nested transactions are savepoints |
| `close` | Close the database once earlier calls finish |
| `database` | For drivers: a `Database` from `run`, `script` and `close` functions |

A database is one connection, so calls run one at a time in the order they
were made. While a transaction is open, other calls wait for it to finish
instead of running inside it.

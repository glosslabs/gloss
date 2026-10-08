# gloss_sql_async

Runs [`gloss/sql`](../gloss_sql) statements in JavaScript, returning
Promises. Imported as `gloss/sql_async`, it is the browser's counterpart to
`gloss/sql/pool`, used by [`gloss_sqlite_wasm`](../gloss_sqlite_wasm) and
[`gloss_pglite`](../gloss_pglite).

```gleam
use db <- promise.try_await(pglite.open(pglite.memory()))
sql_async.all(db, recent(20))
```

- `all`, `one`, `optional`, `exec`, `script`, `transaction` (nested ones are savepoints) and `close`.
- Calls run one at a time, in order; other calls wait while a transaction is open.

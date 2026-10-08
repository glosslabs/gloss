# gloss_sqlite_wasm

SQLite in the browser and other JavaScript runtimes, on the official SQLite
WebAssembly build. Imported as `gloss/sqlite/wasm`; it opens a
[`gloss/sql/async`](../gloss_sql_async) database.

```sh
npm install @sqlite.org/sqlite-wasm
```

```gleam
use db <- promise.try_await(wasm.open(wasm.memory()))
async.all(db, recent(20))
```

- `memory()` lasts for the page; `opfs(name)` persists in the origin private file system (Web Worker only).
- Values follow the same rules as [`gloss_sqlite`](../gloss_sqlite) on the server.
- Run `npm install` here before `gleam test`.

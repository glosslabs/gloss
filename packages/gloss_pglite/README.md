# gloss_pglite

[PGlite](https://pglite.dev), Postgres compiled to WebAssembly, in the
browser and other JavaScript runtimes. Imported as `gloss/pglite`; it opens a
[`gloss/sql_async`](../gloss_sql_async) database.

```sh
npm install @electric-sql/pglite
```

```gleam
use db <- promise.try_await(pglite.open(pglite.indexed_db("app")))
sql_async.one(db, find_note(id))
```

- Storage: `memory()`, `indexed_db(name)`, `opfs(name)` (Web Worker only), or `directory(path)` in Node, Deno and Bun.
- Values and errors are read exactly as [`gloss_pg`](../gloss_pg) reads them, so statements and decoders can be shared with the server.
- Run `npm install` here before `gleam test`.

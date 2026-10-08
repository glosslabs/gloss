# gloss_pglite

[PGlite](https://pglite.dev), Postgres compiled to WebAssembly, for
[`gloss/sql`](../gloss_sql): a real Postgres in the browser, or in Node, Deno
and Bun. Imported as `gloss/pglite`; it opens a
[`gloss/sql/async`](../gloss_sql_async) database.

```sh
npm install @electric-sql/pglite
```

```gleam
import gleam/javascript/promise
import gloss/pglite
import gloss/sql
import gloss/sql/async

use db <- promise.try_await(pglite.open(pglite.indexed_db("app")))
sql.query("select id, title from notes where id = $1")
|> sql.bind(sql.Int(id))
|> sql.returning(note_decoder())
|> async.one(db, _)
```

| Storage | |
|---|---|
| `pglite.memory()` | For the life of the page or process |
| `pglite.indexed_db(name)` | In the browser's IndexedDB, surviving reloads |
| `pglite.opfs(name)` | In the origin private file system; only inside a Web Worker |
| `pglite.directory(path)` | A directory on disk, in Node, Deno or Bun |

PGlite hands every value over as Postgres's own text, which gloss decodes
with the same code [`gloss_pg`](../gloss_pg) uses on the server: the same
types become the same Gleam values (microsecond timestamps, `bytea` as
`Bytes`, arrays as lists, `numeric` as exact text), and errors map by
SQLSTATE to `UniqueViolation`, `ForeignKeyViolation`, `NotNullViolation` and
`CheckViolation`. Sessions run in UTC with ISO dates, as `gloss_pg`'s do. So
statements and decoders written for the server work unchanged in the
browser.

PGlite is one connection: calls run in turn, and a transaction holds the
database until it finishes. There is no query timeout.

Bundlers such as Vite serve PGlite's `pglite.wasm`, `pglite.data` and
`initdb.wasm`; without one, put them next to the bundled script that imports
the package.

Tests run on Node (`npm install` here, then `gleam test`), and IndexedDB
storage has been checked in Chrome, surviving a reload.

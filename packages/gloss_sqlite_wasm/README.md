# gloss_sqlite_wasm

SQLite in the browser and other JavaScript runtimes for
[`gloss/sql`](../gloss_sql), on the official SQLite WebAssembly build.
Imported as `gloss/sqlite/wasm`; it opens a
[`gloss/sql/async`](../gloss_sql_async) database.

```sh
npm install @sqlite.org/sqlite-wasm
```

```gleam
import gleam/javascript/promise
import gloss/sql
import gloss/sql/async
import gloss/sqlite/wasm

use db <- promise.try_await(wasm.open(wasm.memory()))
use _ <- promise.try_await(async.script(db, schema))
sql.query("select id, title from notes order by id desc")
|> sql.returning(note_decoder())
|> async.all(db, _)
```

| Storage | |
|---|---|
| `wasm.memory()` | For the life of the page |
| `wasm.opfs(name)` | In the origin private file system, surviving reloads. Only works in a Web Worker: run the database there and message it from the page |

Values, placeholders (`?1`) and errors follow the same rules as the BEAM
driver, [`gloss_sqlite`](../gloss_sqlite), so statements and decoders can be
shared between server and browser. Integers beyond 2^53 lose precision, as
JavaScript numbers do. Statements run on the calling thread, so there is no
query timeout.

Bundlers such as Vite serve the package's `sqlite3.wasm` file; without one,
put `sqlite3.wasm` next to the bundled script that imports the package.

Tests run on Node (`npm install` here, then `gleam test`), and the memory and
OPFS storage have been checked in Chrome.

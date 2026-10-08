# gloss_pg

A Postgres driver for [`gloss/sql/pool`](../gloss), imported as `gloss/pg`. It
speaks the Postgres wire protocol directly over `gen_tcp`, with no
dependencies beyond `gloss` and the gleam-lang packages.

```gleam
import gloss/pg
import gloss/sql
import gloss/sql/pool

let assert Ok(config) = pg.from_url("postgres://app:secret@localhost/app")
let assert Ok(db) = pool.new(pg.driver(config)) |> pool.size(10) |> pool.start
```

It supports SCRAM-SHA-256, MD5 and cleartext passwords, and TLS
(`pg.ssl` or `?sslmode=`). Arguments are sent as text and typed by the
server, so `sql.Text` serves `uuid`, `json` and `numeric` columns, and
`sql.Array` serves `= any($1)`. Columns come back as Gleam values: ints,
floats, bools, bytes, dates, times, timestamps and arrays of them, and
everything else as text.

Each connection caches up to 100 prepared statements (`pg.statement_cache`;
`0` for PgBouncer in transaction mode), so a statement is parsed once and
then only bound and run. A cached statement invalidated by a schema change
or `DEALLOCATE` is prepared again.

```gleam
// COPY, on a pooled connection or inside a transaction
pg.copy_in(db, "copy items (name, qty) from stdin", [
  pg.copy_row([sql.Text("bolt"), sql.Int(40)]),
])
pg.copy_out(db, "copy items to stdout", from: [], with: fn(rows, row) { [row, ..rows] })

// LISTEN/NOTIFY: a listener has its own connection and reconnects on loss
let assert Ok(listener) = pg.start_listener(config)
let assert Ok(Nil) = pg.listen(listener, "jobs", subject)
pool.exec(db, pg.notify("jobs", "42"))   // subject gets pg.Notification(..)
```

The tests that need a server run when `GLOSS_TEST_PG_URL` is set, e.g.
`GLOSS_TEST_PG_URL=postgres://postgres:secret@127.0.0.1:5432/postgres gleam test`.

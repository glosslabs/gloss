# gloss_sql_pool

Runs [`gloss/sql`](../gloss_sql) statements on the BEAM through a pool of
connections from a driver such as [`gloss/pg`](../gloss_pg),
[`gloss/mysql`](../gloss_mysql) or [`gloss/sqlite`](../gloss_sqlite).
Imported as `gloss/sql/pool`.

```gleam
import gloss/pg
import gloss/sql
import gloss/sql/pool

let assert Ok(config) = pg.from_url("postgres://app:secret@localhost/app")
let assert Ok(db) = pool.new(pg.driver(config)) |> pool.size(10) |> pool.start

sql.query("select id, email from users where id = $1")
|> sql.bind(sql.Int(id))
|> sql.returning(user_decoder)
|> pool.one(db, _)
```

- `all`, `one`, `optional`, `exec` and `script`; `transaction`, with savepoints when nested and `BEGIN` sent with the first statement.
- Every statement is a tracer span that joins the current request's trace.
- `reply` answers a `gloss/store` message with a statement's result.

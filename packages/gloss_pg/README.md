# gloss_pg

A Postgres driver for [`gloss/sql/pool`](../gloss), speaking the wire
protocol directly. Imported as `gloss/pg`.

```gleam
let assert Ok(config) = pg.from_url("postgres://app:secret@localhost/app")
let assert Ok(db) = pool.new(pg.driver(config)) |> pool.start

sql.query("select email from users where id = $1")
|> sql.bind(sql.Int(id))
|> sql.returning(decode.at([0], decode.string))
|> pool.one(db, _)
```

- SCRAM authentication, TLS (`sslmode`), and a per-connection cache of prepared statements.
- `listen`/`notify` for LISTEN and NOTIFY; `copy_in`/`copy_out` for COPY.
- Its live tests run when `GLOSS_TEST_PG_URL` is set.

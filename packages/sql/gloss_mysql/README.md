# gloss_mysql

A MySQL driver for [`gloss/sql/pool`](../../gloss), speaking the protocol
directly. Imported as `gloss/mysql`.

```gleam
let assert Ok(config) = mysql.from_url("mysql://app:secret@localhost:3306/app")
let assert Ok(db) = pool.new(mysql.driver(config)) |> pool.start

sql.query("select email from users where id = ?")
|> sql.bind(sql.Int(id))
|> sql.returning(decode.at([0], decode.string))
|> pool.one(db, _)
```

- caching_sha2_password and mysql_native_password, TLS (`ssl-mode`), cached prepared statements.
- `DATETIME` and `TIMESTAMP` read as UTC timestamps; `insert_id` for `AUTO_INCREMENT` keys.
- Its live tests run when `GLOSS_TEST_MYSQL_URL` is set (add `GLOSS_TEST_MYSQL_TLS=1` to test TLS).

# gloss_mysql

A MySQL driver for [`gloss/sql/pool`](../gloss), imported as `gloss/mysql`.
It speaks the MySQL client/server protocol directly over `gen_tcp`, with no
dependencies beyond `gloss`, [`gloss_sql`](../gloss_sql) and the gleam-lang
packages.

```gleam
import gloss/mysql
import gloss/sql
import gloss/sql/pool

let assert Ok(config) = mysql.from_url("mysql://app:secret@localhost:3306/app")
let assert Ok(db) = pool.new(mysql.driver(config)) |> pool.size(10) |> pool.start

sql.query("select id, email from users where id = ?")
|> sql.bind(sql.Int(id))
|> sql.returning(user)
|> pool.one(db, _)
```

Placeholders are `?`. Statements with arguments run as prepared statements
over the binary protocol, so arguments are typed on the wire and never
spliced into the SQL. Each connection caches up to 100 of them
(`mysql.statement_cache`; `0` for a multiplexing proxy such as ProxySQL).

Columns come back as Gleam values: integers, `TINYINT(1)` as `Bool`,
`FLOAT`/`DOUBLE`, `DATE`, `TIME` and `DATETIME`/`TIMESTAMP` (as
`Timestamp`), binary strings and blobs as bytes, and `DECIMAL`, text, `ENUM`,
`SET` and `JSON` as strings. Every connection sets `time_zone = '+00:00'`,
so timestamps are read and written in UTC. MySQL has no arrays, so
`sql.Array` arguments are refused.

It supports `caching_sha2_password` (MySQL 8's default, including full
authentication over TLS or with the server's RSA key) and
`mysql_native_password`, and TLS (`mysql.ssl` or `?ssl-mode=`). Server
errors map onto `sql.Error`: duplicate keys, foreign keys, NOT NULL and
CHECK constraints are broken out, and other errors carry the MySQL error
number as their code (`"1146"`).

`UPDATE` counts matched rows, as Postgres does. MySQL has no `RETURNING`,
so `mysql.insert_id` runs an `INSERT` and returns its `AUTO_INCREMENT` id
from the same connection:

```gleam
sql.query("insert into users (email) values (?)")
|> sql.bind(sql.Text(email))
|> mysql.insert_id(db, _)
```

`pool.script` runs several statements separated by `;`, such as a schema.
`mysql.on_connect` adds SQL to run on every new connection, e.g. to set
`sql_mode`.

The tests that need a server run when `GLOSS_TEST_MYSQL_URL` is set, e.g.:

```sh
docker run -d --name gloss-mysql-test -p 3307:3306 \
  -e MYSQL_ROOT_PASSWORD=secret -e MYSQL_DATABASE=gloss \
  mysql:8.4 --mysql-native-password=ON
GLOSS_TEST_MYSQL_URL=mysql://root:secret@127.0.0.1:3307/gloss gleam test
```

Add `GLOSS_TEST_MYSQL_TLS=1` to also test TLS, which MySQL 8 serves with a
self-signed certificate by default.

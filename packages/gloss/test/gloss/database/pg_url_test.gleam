import gleam/erlang/process
import gloss/database/pg
import gloss/database/sql

pub fn rejects_other_schemes_test() {
  assert pg.from_url("mysql://localhost/db") == Error(Nil)
  assert pg.from_url("postgres://localhost/db?sslmode=bogus") == Error(Nil)
}

pub fn reads_every_part_of_a_url_test() {
  let assert Ok(config) =
    pg.from_url(
      "postgresql://app%40corp:p%2Fss@db.internal:6543/my%20db?sslmode=verify-full&search_path=app",
    )
  assert config
    == pg.new()
    |> pg.host("db.internal")
    |> pg.port(6543)
    |> pg.user("app@corp")
    |> pg.password("p/ss")
    |> pg.database("my db")
    |> pg.ssl(pg.SslVerified)
    |> pg.parameter("search_path", "app")
}

pub fn an_unreachable_server_fails_to_connect_test() {
  let assert Ok(db) =
    sql.new(pg.driver(pg.new() |> pg.host("127.0.0.1") |> pg.port(1)))
    |> sql.start
  let assert Error(sql.ConnectionFailed(_)) =
    sql.exec(db, sql.query("select 1"))
  sql.shutdown(db)
  process.sleep(10)
}

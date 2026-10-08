import gleam/erlang/process
import gleam/time/duration
import gloss/mysql
import gloss/sql
import gloss/sql/pool

pub fn rejects_other_schemes_and_unknown_parameters_test() {
  assert mysql.from_url("postgres://localhost/db") == Error(Nil)
  assert mysql.from_url("mysql://localhost/db?ssl-mode=bogus") == Error(Nil)
  assert mysql.from_url("mysql://localhost/db?charset=latin1") == Error(Nil)
}

pub fn reads_every_part_of_a_url_test() {
  let assert Ok(config) =
    mysql.from_url(
      "mysql://app%40corp:p%2Fss@db.internal:3307/my%20db?ssl-mode=VERIFY_IDENTITY&connect_timeout=2",
    )
  assert config
    == mysql.new()
    |> mysql.host("db.internal")
    |> mysql.port(3307)
    |> mysql.user("app@corp")
    |> mysql.password("p/ss")
    |> mysql.database("my db")
    |> mysql.ssl(mysql.SslVerified)
    |> mysql.connect_timeout(duration.seconds(2))
  let assert Ok(config) = mysql.from_url("mysql://localhost?sslmode=require")
  assert config == mysql.new() |> mysql.ssl(mysql.SslRequired)
}

pub fn an_unreachable_server_fails_to_connect_test() {
  let assert Ok(db) =
    pool.new(mysql.driver(
      mysql.new() |> mysql.host("127.0.0.1") |> mysql.port(1),
    ))
    |> pool.start
  let assert Error(sql.ConnectionFailed(_)) =
    pool.exec(db, sql.query("select 1"))
  pool.shutdown(db)
  process.sleep(10)
}

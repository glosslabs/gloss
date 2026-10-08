//// Drivers against live services. Each runs when its URL is set:
//// GLOSS_BENCH_PG_URL, GLOSS_BENCH_MYSQL_URL, GLOSS_BENCH_REDIS_URL,
//// GLOSS_BENCH_S3_ENDPOINT (with gloss/glosssecret credentials). SQLite
//// always runs.

import bench/harness.{bench, bench_concurrent, section}
import envoy
import gleam/bit_array
import gleam/dynamic/decode
import gleam/httpc
import gleam/int
import gleam/option.{None}
import gleam/result
import gleam/string
import gloss/mysql
import gloss/pg
import gloss/redis
import gloss/s3
import gloss/sql
import gloss/sql/pool
import gloss/sqlite

pub fn run() -> Nil {
  case envoy.get("GLOSS_BENCH_PG_URL") {
    Ok(url) -> {
      let assert Ok(config) = pg.from_url(url)
      database("gloss/pg (Postgres)", pg.driver(config), "$1", "serial")
    }
    Error(Nil) -> Nil
  }
  case envoy.get("GLOSS_BENCH_MYSQL_URL") {
    Ok(url) -> {
      let assert Ok(config) = mysql.from_url(url)
      database(
        "gloss/mysql (MySQL)",
        mysql.driver(config),
        "?",
        "int auto_increment",
      )
    }
    Error(Nil) -> Nil
  }
  database(
    "gloss/sqlite (memory)",
    sqlite.driver(sqlite.memory()),
    "?1",
    "integer",
  )
  database(
    "gloss/sqlite (file, WAL)",
    sqlite.driver(sqlite.file(
      "build/bench-" <> int.to_string(system_time()) <> ".db",
    )),
    "?1",
    "integer",
  )
  case envoy.get("GLOSS_BENCH_REDIS_URL") {
    Ok(url) -> redis_bench(url)
    Error(Nil) -> Nil
  }
  case envoy.get("GLOSS_BENCH_S3_ENDPOINT") {
    Ok(endpoint) -> s3_bench(endpoint)
    Error(Nil) -> Nil
  }
}

fn database(
  title: String,
  driver: pool.Driver,
  placeholder: String,
  key_type: String,
) -> Nil {
  section(title)
  let assert Ok(db) = pool.new(driver) |> pool.size(10) |> pool.start
  let assert Ok(_) = pool.script(db, "drop table if exists bench_users")
  let assert Ok(_) =
    pool.script(
      db,
      "create table bench_users (id "
        <> key_type
        <> " primary key, email varchar(200) not null, score int not null)",
    )
  let insert = fn(n) {
    sql.query("insert into bench_users (email, score) values (")
    |> sql.append(placeholder)
    |> sql.append(", 1)")
    |> sql.bind(sql.Text("user" <> int.to_string(n) <> "@example.com"))
  }
  let assert Ok(_) =
    pool.transaction(db, fn(tx) {
      int.range(from: 1, to: 1001, with: Ok(0), run: fn(acc, n) {
        result.try(acc, fn(_) { pool.exec(tx, insert(n)) })
      })
    })
  let find = fn(id) {
    sql.query("select id, email, score from bench_users where id = ")
    |> sql.append(placeholder)
    |> sql.bind(sql.Int(id))
    |> sql.returning({
      use id <- decode.field(0, decode.int)
      use email <- decode.field(1, decode.string)
      use score <- decode.field(2, decode.int)
      decode.success(#(id, email, score))
    })
  }
  let counter = new_counter()
  let next_id = fn() { next(counter) % 1000 + 1 }
  bench("select 1 (round trip)", 2000, fn() {
    pool.one(db, sql.query("select 1") |> sql.returning(decode.at([0], decode.int)))
  })
  bench("select a row by id", 2000, fn() { pool.one(db, find(next_id())) })
  bench_concurrent("select a row by id, 50 callers, pool of 10", 50, 200, fn() {
    pool.one(db, find(next_id()))
  })
  bench("insert a row", 1000, fn() { pool.exec(db, insert(next(counter))) })
  bench_concurrent("insert a row, 50 callers", 50, 40, fn() {
    pool.exec(db, insert(next(counter)))
  })
  bench("transaction: select and update", 1000, fn() {
    pool.transaction(db, fn(tx) {
      let id = next_id()
      use _ <- result.try(pool.one(tx, find(id)))
      sql.query("update bench_users set score = score + 1 where id = ")
      |> sql.append(placeholder)
      |> sql.bind(sql.Int(id))
      |> pool.exec(tx, _)
    })
  })
  let assert Ok(_) = pool.script(db, "drop table bench_users")
  pool.shutdown(db)
}

fn redis_bench(url: String) -> Nil {
  section("gloss/redis")
  let assert Ok(config) = redis.from_url(url)
  let assert Ok(r) = redis.start(config)
  let assert Ok(Nil) = redis.set(r, "bench:key", "value")
  bench("GET", 5000, fn() { redis.get(r, "bench:key") })
  bench("SET", 5000, fn() { redis.set(r, "bench:key", "value") })
  bench_concurrent("GET, 50 callers", 50, 400, fn() { redis.get(r, "bench:key") })
  let batch = list_repeat(["SET", "bench:key", "value"], 100)
  bench("pipeline of 100 SETs", 200, fn() { redis.pipeline(r, batch) })
  redis.shutdown(r)
}

fn s3_bench(endpoint: String) -> Nil {
  section("gloss/s3")
  let client =
    s3.new(
      access_key_id: "gloss",
      secret_access_key: "glosssecret",
      region: "us-east-1",
      send: httpc.send_bits,
    )
    |> s3.endpoint(endpoint)
  let bucket = s3.bucket(client, "bench-" <> int.to_string(system_time()))
  let assert Ok(Nil) = s3.create_bucket(bucket)
  let small = bit_array.from_string(string.repeat("x", 1024))
  let large = bit_array.from_string(string.repeat("x", 1024 * 1024))
  bench("put 1 KiB", 300, fn() {
    s3.put_object(bucket, "small", small, s3.put_options())
  })
  bench("get 1 KiB", 300, fn() { s3.get_object(bucket, "small", range: None) })
  bench("put 1 MiB", 50, fn() {
    s3.put_object(bucket, "large", large, s3.put_options())
  })
  bench("get 1 MiB", 50, fn() { s3.get_object(bucket, "large", range: None) })
  Nil
}

fn list_repeat(item: a, times: Int) -> List(a) {
  int.range(from: 0, to: times, with: [], run: fn(acc, _) { [item, ..acc] })
}

type Counter

@external(erlang, "bench@services_ffi", "new_counter")
fn new_counter() -> Counter

@external(erlang, "bench@services_ffi", "next")
fn next(counter: Counter) -> Int

@external(erlang, "os", "system_time")
fn system_time() -> Int

//// Tests against a real MySQL. They run only when GLOSS_TEST_MYSQL_URL is
//// set, e.g. `mysql://root:secret@127.0.0.1:3307/gloss`.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gloss/mysql
import gloss/sql
import gloss/sql/pool

fn config() -> Result(mysql.Config, Nil) {
  getenv("GLOSS_TEST_MYSQL_URL") |> result.try(mysql.from_url)
}

fn with_config(config: mysql.Config, size: Int, test_: fn(pool.Db) -> Nil) {
  let assert Ok(db) =
    pool.new(mysql.driver(config))
    |> pool.size(size)
    |> pool.query_timeout(duration.milliseconds(500))
    |> pool.start
  test_(db)
  pool.shutdown(db)
}

fn with_db(size: Int, test_: fn(pool.Db) -> Nil) -> Nil {
  case config() {
    Error(Nil) -> Nil
    Ok(config) -> with_config(config, size, test_)
  }
}

fn count(db: pool.Db, table: String) -> Int {
  let assert Ok(n) =
    sql.query("select count(*) from " <> table)
    |> sql.returning(decode.at([0], decode.int))
    |> pool.one(db, _)
  n
}

pub fn reads_column_types_test() {
  use db <- with_db(1)
  let assert Ok(Nil) =
    pool.script(
      db,
      "create temporary table types (
         b tinyint(1), i bigint, u int unsigned, f double, fl float,
         d decimal(10, 2), t varchar(20), bin varbinary(10), dt date,
         tm time(6), ts timestamp(6) null, dtm datetime(6), j json,
         e enum('a', 'b'), y year, nul int
       );
       insert into types values (
         true, 9000000000, 4000000000, 1.5, 1.5, 12.50, 'héllo',
         x'00ff', '2024-02-29', '03:04:05.5', '2024-01-02 03:04:05',
         '2024-01-02 03:04:05.25', '{\"a\": 1}', 'b', 2024, null
       );",
    )
  let row = {
    use b <- decode.field(0, decode.bool)
    use i <- decode.field(1, decode.int)
    use u <- decode.field(2, decode.int)
    use f <- decode.field(3, decode.float)
    use fl <- decode.field(4, decode.float)
    use d <- decode.field(5, decode.string)
    use t <- decode.field(6, decode.string)
    use bin <- decode.field(7, decode.bit_array)
    use dt <- decode.field(8, sql.date_decoder())
    use tm <- decode.field(9, sql.time_decoder())
    use ts <- decode.field(10, sql.timestamp_decoder())
    use dtm <- decode.field(11, sql.timestamp_decoder())
    use j <- decode.field(12, decode.string)
    use e <- decode.field(13, decode.string)
    use y <- decode.field(14, decode.int)
    use nul <- decode.field(15, decode.optional(decode.int))
    decode.success(#(
      #(b, i, u, f, fl, d, t, bin),
      #(dt, tm, ts, dtm, j, e, y, nul),
    ))
  }
  let assert Ok(values) =
    sql.query("select * from types") |> sql.returning(row) |> pool.one(db, _)
  assert values
    == #(
      #(True, 9_000_000_000, 4_000_000_000, 1.5, 1.5, "12.50", "héllo", <<
        0,
        255,
      >>),
      #(
        calendar.Date(2024, calendar.February, 29),
        calendar.TimeOfDay(3, 4, 5, 500_000_000),
        timestamp.from_unix_seconds(1_704_164_645),
        timestamp.from_unix_seconds_and_nanoseconds(1_704_164_645, 250_000_000),
        "{\"a\": 1}",
        "b",
        2024,
        None,
      ),
    )
}

pub fn round_trips_arguments_test() {
  use db <- with_db(1)
  let at =
    timestamp.from_unix_seconds_and_nanoseconds(1_704_164_645, 123_456_000)
  let args = [
    sql.Text("it's \"quoted\" ünicode"),
    sql.Int(-42),
    sql.Bool(False),
    sql.Timestamp(at),
    sql.Date(calendar.Date(2024, calendar.March, 1)),
    sql.Bytes(<<1, 2, 3, 0>>),
    sql.Float(0.1),
    sql.Null,
    sql.Time(calendar.TimeOfDay(23, 59, 58, 1000)),
  ]
  let assert Ok(Nil) =
    pool.script(
      db,
      "create temporary table args (
         t text, i bigint, b tinyint(1), ts datetime(6), d date,
         bin blob, f double, n int, tm time(6)
       )",
    )
  let assert Ok(1) =
    list.fold(
      args,
      sql.query("insert into args values (?, ?, ?, ?, ?, ?, ?, ?, ?)"),
      sql.bind,
    )
    |> pool.exec(db, _)
  let assert Ok(row) =
    sql.query("select * from args")
    |> sql.returning({
      use t <- decode.field(0, decode.string)
      use i <- decode.field(1, decode.int)
      use b <- decode.field(2, decode.bool)
      use ts <- decode.field(3, sql.timestamp_decoder())
      use d <- decode.field(4, sql.date_decoder())
      use bin <- decode.field(5, decode.bit_array)
      use f <- decode.field(6, decode.float)
      use n <- decode.field(7, decode.optional(decode.int))
      use tm <- decode.field(8, sql.time_decoder())
      decode.success(#(t, i, b, ts, d, bin, f, n, tm))
    })
    |> pool.one(db, _)
  assert row
    == #(
      "it's \"quoted\" ünicode",
      -42,
      False,
      at,
      calendar.Date(2024, calendar.March, 1),
      <<1, 2, 3, 0>>,
      0.1,
      None,
      calendar.TimeOfDay(23, 59, 58, 1000),
    )
  // Arguments in an expression, typed by the binary protocol.
  let assert Ok(n) =
    sql.query("select ? * 2")
    |> sql.bind(sql.Int(21))
    |> sql.returning(decode.at([0], decode.int))
    |> pool.one(db, _)
  assert n == 42
}

pub fn maps_constraint_errors_test() {
  use db <- with_db(1)
  let assert Ok(Nil) =
    pool.script(
      db,
      "drop table if exists people;
       drop table if exists teams;
       create table teams (id int primary key);
       create table people (
         id int auto_increment primary key,
         email varchar(50) not null,
         age int,
         team int,
         constraint people_email_key unique (email),
         constraint people_age_check check (age >= 0),
         constraint people_team_fk foreign key (team) references teams (id)
       );
       insert into people (email) values ('a@x');",
    )
  let insert = fn(email, age) {
    sql.query("insert into people (email, age) values (?, ?)")
    |> sql.bind(email)
    |> sql.bind(age)
    |> pool.exec(db, _)
  }
  let assert Error(sql.UniqueViolation(constraint: "people_email_key", ..)) =
    insert(sql.Text("a@x"), sql.Null)
  let assert Error(sql.NotNullViolation(column: "email", ..)) =
    insert(sql.Null, sql.Null)
  let assert Error(sql.CheckViolation(constraint: "people_age_check", ..)) =
    insert(sql.Text("b@x"), sql.Int(-1))
  let assert Error(sql.ForeignKeyViolation(constraint: "people_team_fk", ..)) =
    sql.query("insert into people (email, team) values ('c@x', 9)")
    |> pool.exec(db, _)
  assert insert(sql.Text("b@x"), sql.Int(3)) == Ok(1)
  // Matched rows, not only changed ones.
  assert pool.exec(db, sql.query("update people set age = 3")) == Ok(2)
  assert pool.exec(db, sql.query("update people set age = 3")) == Ok(2)
  let assert Ok(Nil) = pool.script(db, "drop table people; drop table teams")
  Nil
}

pub fn insert_id_test() {
  use db <- with_db(1)
  let assert Ok(Nil) =
    pool.script(
      db,
      "create temporary table auto (id int auto_increment primary key, v int)",
    )
  let insert = fn(v) {
    sql.query("insert into auto (v) values (?)")
    |> sql.bind(sql.Int(v))
    |> mysql.insert_id(db, _)
  }
  assert insert(10) == Ok(1)
  assert insert(20) == Ok(2)
  // In a transaction too, on the transaction's connection.
  let assert Ok(3) =
    pool.transaction(db, fn(tx) {
      sql.query("insert into auto (v) values (30)") |> mysql.insert_id(tx, _)
    })
    |> sql.flatten
  Nil
}

pub fn a_failed_statement_leaves_the_connection_usable_test() {
  use db <- with_db(1)
  let assert Error(sql.QueryFailed(code: "1064", ..)) =
    pool.exec(db, sql.query("selec 1"))
  let assert Error(sql.QueryFailed(code: "1146", ..)) =
    pool.exec(db, sql.query("select * from no_such_table"))
  assert pool.exec(db, sql.query("select 1")) == Ok(1)
  // A placeholder count mismatch is caught before anything runs.
  let assert Error(sql.QueryFailed(code: "", ..)) =
    pool.exec(db, sql.query("select ?"))
  assert pool.exec(db, sql.query("select 1")) == Ok(1)
}

pub fn scripts_run_several_statements_test() {
  use db <- with_db(1)
  let assert Ok(Nil) =
    pool.script(
      db,
      "create temporary table s (n int);
       insert into s values (1), (2);
       select * from s;
       insert into s values (3);",
    )
  assert count(db, "s") == 3
  // An error stops the script.
  let assert Error(sql.QueryFailed(code: "1146", ..)) =
    pool.script(
      db,
      "insert into s values (4); select * from nope; insert into s values (5)",
    )
  assert count(db, "s") == 4
}

pub fn transactions_commit_and_roll_back_test() {
  use db <- with_db(1)
  let assert Ok(Nil) =
    pool.script(db, "create temporary table items (name text) engine=InnoDB")
  let add = fn(db, name) {
    sql.query("insert into items values (?)")
    |> sql.bind(sql.Text(name))
    |> pool.exec(db, _)
  }

  let assert Error(sql.RolledBack("no")) =
    pool.transaction(db, fn(tx) {
      let _ = add(tx, "dropped")
      Error("no")
    })
  assert count(db, "items") == 0

  let assert Ok(Nil) =
    pool.transaction(db, fn(tx) {
      let _ = add(tx, "kept")
      let _ =
        pool.transaction(tx, fn(inner) {
          let _ = add(inner, "undone")
          Error(Nil)
        })
      Ok(Nil)
    })
  assert count(db, "items") == 1
}

pub fn a_slow_statement_times_out_test() {
  use db <- with_db(1)
  assert pool.exec(db, sql.query("select sleep(2)")) == Error(sql.QueryTimeout)
  assert pool.exec(db, sql.query("select 1")) == Ok(1)
}

pub fn a_timeout_inside_a_transaction_breaks_the_connection_test() {
  use db <- with_db(1)
  let select_42 =
    sql.query("select 42") |> sql.returning(decode.at([0], decode.int))
  let assert Error(sql.RolledBack(sql.ConnectionLost(_))) =
    pool.transaction(db, fn(tx) {
      let assert Error(sql.QueryTimeout) =
        pool.exec(tx, sql.query("select sleep(0.7)"))
      process.sleep(300)
      pool.one(tx, select_42)
    })
  assert pool.one(db, select_42) == Ok(42)
}

pub fn serves_concurrent_callers_test() {
  use db <- with_db(3)
  let results = process.new_subject()
  one_to(20)
  |> list.each(fn(i) {
    process.spawn(fn() {
      let result =
        sql.query("select ? * 2")
        |> sql.bind(sql.Int(i))
        |> sql.returning(decode.at([0], decode.int))
        |> pool.one(db, _)
      process.send(results, result)
    })
  })
  let total =
    one_to(20)
    |> list.map(fn(_) {
      let assert Ok(Ok(n)) = process.receive(results, 5000)
      n
    })
    |> list.fold(0, fn(a, b) { a + b })
  assert total == 420
}

pub fn the_statement_cache_evicts_and_closes_test() {
  case config() {
    Error(Nil) -> Nil
    Ok(config) -> {
      use db <- with_config(mysql.statement_cache(config, 2), 1)
      let select = fn(n) {
        sql.query("select ? + " <> int.to_string(n))
        |> sql.bind(sql.Int(1))
        |> sql.returning(decode.at([0], decode.int))
        |> pool.one(db, _)
      }
      // Ten statements through a cache of two, twice over.
      list.each([1, 2], fn(_) {
        list.each(one_to(10), fn(n) {
          let assert Ok(m) = select(n)
          assert m == n + 1
        })
      })
      // Evicted statements were closed on the server: all but the two
      // cached of the ten, on each pass.
      let assert Ok(closed) =
        sql.query("show session status like 'Com_stmt_close'")
        |> sql.returning(decode.at([1], decode.string))
        |> pool.one(db, _)
      let assert Ok(closed) = int.parse(closed)
      assert closed >= 16
      // Off entirely.
      use db <- with_config(mysql.statement_cache(config, 0), 1)
      let assert Ok(2) =
        sql.query("select ? + 1")
        |> sql.bind(sql.Int(1))
        |> sql.returning(decode.at([0], decode.int))
        |> pool.one(db, _)
      Nil
    }
  }
}

pub fn large_rows_span_several_packets_test() {
  use config <- with_url
  let assert Ok(db) =
    pool.new(mysql.driver(config))
    |> pool.size(1)
    |> pool.query_timeout(duration.seconds(30))
    |> pool.start
  // Over 16 MiB each way, so packets are split and joined.
  let big =
    bit_array.concat(list.repeat(<<"0123456789abcdef":utf8>>, 1_100_000))
  let assert Ok(Nil) =
    pool.script(db, "create temporary table big (b longblob)")
  let assert Ok(1) =
    sql.query("insert into big values (?)")
    |> sql.bind(sql.Bytes(big))
    |> pool.exec(db, _)
  let assert Ok(read) =
    sql.query("select b, length(b) from big")
    |> sql.returning({
      use b <- decode.field(0, decode.bit_array)
      use n <- decode.field(1, decode.int)
      decode.success(#(b, n))
    })
    |> pool.one(db, _)
  assert read.1 == 17_600_000
  assert read.0 == big
  pool.shutdown(db)
}

fn with_url(test_: fn(mysql.Config) -> Nil) -> Nil {
  case config() {
    Error(Nil) -> Nil
    Ok(config) -> test_(config)
  }
}

/// caching_sha2_password's full authentication (no TLS, so with the
/// server's RSA key) the first time, its fast path after that, and
/// mysql_native_password.
pub fn authenticates_with_each_plugin_test() {
  case config() {
    Error(Nil) -> Nil
    Ok(config) -> {
      use db <- with_config(config, 1)
      let assert Ok(Nil) =
        pool.script(
          db,
          "drop user if exists 'gloss_sha2'@'%', 'gloss_native'@'%';
           create user 'gloss_sha2'@'%'
             identified with caching_sha2_password by 'sha2 secret';
           grant select on gloss.* to 'gloss_sha2'@'%';",
        )
      let as_user = fn(user, password) {
        config |> mysql.user(user) |> mysql.password(password)
      }
      list.each([1, 2], fn(_) {
        use db <- with_config(as_user("gloss_sha2", "sha2 secret"), 1)
        assert pool.exec(db, sql.query("select 1")) == Ok(1)
      })
      // The native plugin is off unless the server enables it.
      case
        pool.script(
          db,
          "create user 'gloss_native'@'%'
             identified with mysql_native_password by 'native secret';
           grant select on gloss.* to 'gloss_native'@'%';",
        )
      {
        Ok(Nil) -> {
          use db <- with_config(as_user("gloss_native", "native secret"), 1)
          assert pool.exec(db, sql.query("select 1")) == Ok(1)
        }
        Error(_) -> Nil
      }
      let assert Ok(Nil) =
        pool.script(
          db,
          "drop user if exists 'gloss_sha2'@'%', 'gloss_native'@'%'",
        )
      Nil
    }
  }
}

pub fn a_wrong_password_fails_to_connect_test() {
  case config() {
    Error(Nil) -> Nil
    Ok(config) -> {
      let assert Ok(db) =
        pool.new(mysql.driver(mysql.password(config, "wrong"))) |> pool.start
      let assert Error(sql.ConnectionFailed(_)) =
        pool.exec(db, sql.query("select 1"))
      pool.shutdown(db)
    }
  }
}

/// Runs when the test server has TLS on (MySQL 8 does by default) and
/// GLOSS_TEST_MYSQL_TLS is set.
pub fn connects_over_tls_test() {
  case getenv("GLOSS_TEST_MYSQL_TLS"), config() {
    Ok(_), Ok(config) -> {
      use db <- with_config(mysql.ssl(config, mysql.SslRequired), 2)
      list.each(one_to(5), fn(_) {
        let assert Ok(cipher) =
          sql.query("show session status like 'Ssl_cipher'")
          |> sql.returning(decode.at([1], decode.string))
          |> pool.one(db, _)
        assert cipher != ""
      })
      // A new caching_sha2_password user's first login sends the password
      // over TLS.
      let assert Ok(Nil) =
        pool.script(
          db,
          "drop user if exists 'gloss_tls'@'%';
           create user 'gloss_tls'@'%'
             identified with caching_sha2_password by 'tls secret';
           grant select on gloss.* to 'gloss_tls'@'%';",
        )
      {
        let tls_user =
          config
          |> mysql.ssl(mysql.SslRequired)
          |> mysql.user("gloss_tls")
          |> mysql.password("tls secret")
        use db <- with_config(tls_user, 1)
        assert pool.exec(db, sql.query("select 1")) == Ok(1)
      }
      let assert Ok(Nil) = pool.script(db, "drop user 'gloss_tls'@'%'")
      // A self-signed certificate fails verification.
      let assert Ok(verified) =
        pool.new(mysql.driver(mysql.ssl(config, mysql.SslVerified)))
        |> pool.start
      let assert Error(sql.ConnectionFailed(_)) =
        pool.exec(verified, sql.query("select 1"))
      Nil
    }
    _, _ -> Nil
  }
}

fn one_to(n: Int) -> List(Int) {
  case n {
    0 -> []
    _ -> list.append(one_to(n - 1), [n])
  }
}

@external(erlang, "mysql_test_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

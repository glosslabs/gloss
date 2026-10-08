//// Tests against a real Redis. They run only when GLOSS_TEST_REDIS_URL is
//// set, e.g. `redis://127.0.0.1:6390/0`; the AUTH test also needs
//// GLOSS_TEST_REDIS_AUTH_URL, e.g. `redis://:s3cret@127.0.0.1:6391/0`.

import envoy
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gloss/meta
import gloss/redis.{
  Array, Bulk, Failed, Integer, Null, Published, ServerError, Status,
}
import gloss/tracer

fn with_redis(test_: fn(redis.Redis, String) -> Nil) -> Nil {
  case envoy.get("GLOSS_TEST_REDIS_URL") {
    Error(Nil) -> Nil
    Ok(url) -> {
      let assert Ok(config) = redis.from_url(url)
      let assert Ok(r) =
        config |> redis.timeout(duration.seconds(2)) |> redis.start
      // Keys unique to this test, so tests don't see each other's data.
      let prefix =
        "gloss-test:"
        <> int.to_string(system_time())
        <> "-"
        <> int.to_string(unique())
        <> ":"
      test_(r, prefix)
      redis.shutdown(r)
    }
  }
}

pub fn from_url_test() {
  let assert Ok(_) = redis.from_url("redis://localhost")
  let assert Ok(_) = redis.from_url("rediss://user:p%40ss@cache.example:6380/3")
  let assert Error(Nil) = redis.from_url("http://localhost")
  let assert Error(Nil) = redis.from_url("redis://localhost/x")
}

pub fn strings_test() {
  use r, p <- with_redis
  assert redis.get(r, p <> "missing") == Ok(None)
  assert redis.set(r, p <> "a", "héllo") == Ok(Nil)
  assert redis.get(r, p <> "a") == Ok(Some("héllo"))

  let nx = redis.SetOptions(..redis.set_options(), condition: redis.IfMissing)
  assert redis.set_with(r, p <> "a", "other", nx) == Ok(False)
  assert redis.set_with(r, p <> "b", "new", nx) == Ok(True)
  let xx = redis.SetOptions(..redis.set_options(), condition: redis.IfExists)
  assert redis.set_with(r, p <> "c", "x", xx) == Ok(False)

  assert redis.ttl(r, p <> "a") == Ok(redis.Persistent)
  assert redis.ttl(r, p <> "nope") == Ok(redis.Missing)
  let soon =
    redis.SetOptions(..redis.set_options(), expiry: Some(duration.seconds(60)))
  assert redis.set_with(r, p <> "e", "v", soon) == Ok(True)
  let assert Ok(redis.ExpiresIn(left)) = redis.ttl(r, p <> "e")
  assert duration.to_seconds(left) >. 58.0
  assert redis.expire(r, p <> "a", duration.milliseconds(50)) == Ok(True)
  assert redis.expire(r, p <> "nope", duration.seconds(1)) == Ok(False)
  process.sleep(120)
  assert redis.get(r, p <> "a") == Ok(None)

  assert redis.incr(r, p <> "n") == Ok(1)
  assert redis.incr_by(r, p <> "n", 41) == Ok(42)
  assert redis.mget(r, [p <> "n", p <> "nope", p <> "b"])
    == Ok([Some("42"), None, Some("new")])
  assert redis.exists(r, [p <> "n", p <> "b", p <> "nope"]) == Ok(2)
  assert redis.del(r, [p <> "n", p <> "nope"]) == Ok(1)
}

pub fn hashes_lists_and_sets_test() {
  use r, p <- with_redis
  assert redis.hset(r, p <> "h", [#("name", "ada"), #("lang", "gleam")])
    == Ok(2)
  assert redis.hget(r, p <> "h", "name") == Ok(Some("ada"))
  assert redis.hget(r, p <> "h", "nope") == Ok(None)
  assert redis.hgetall(r, p <> "h")
    == Ok(dict.from_list([#("name", "ada"), #("lang", "gleam")]))
  assert redis.hgetall(r, p <> "none") == Ok(dict.new())
  assert redis.hdel(r, p <> "h", ["lang", "nope"]) == Ok(1)

  assert redis.rpush(r, p <> "l", ["b", "c"]) == Ok(2)
  assert redis.lpush(r, p <> "l", ["a"]) == Ok(3)
  assert redis.lrange(r, p <> "l", 0, -1) == Ok(["a", "b", "c"])
  assert redis.lpop(r, p <> "l") == Ok(Some("a"))
  assert redis.rpop(r, p <> "l") == Ok(Some("c"))
  assert redis.rpop(r, p <> "empty") == Ok(None)

  assert redis.sadd(r, p <> "s", ["x", "y", "x"]) == Ok(2)
  assert redis.srem(r, p <> "s", ["y", "z"]) == Ok(1)
  assert redis.smembers(r, p <> "s") == Ok(["x"])
}

pub fn commands_and_server_errors_test() {
  use r, p <- with_redis
  assert redis.command(r, ["PING"]) == Ok(Status("PONG"))
  assert redis.command(r, ["ZADD", p <> "z", "1", "a", "2", "b"])
    == Ok(Integer(2))
  assert redis.command(r, ["ZRANGE", p <> "z", "0", "-1"])
    == Ok(Array([Bulk(<<"a">>), Bulk(<<"b">>)]))
  assert redis.command(r, ["GET", p <> "nope"]) == Ok(Null)

  let assert Ok(Nil) = redis.set(r, p <> "str", "x")
  let assert Error(ServerError(kind: "WRONGTYPE", ..)) =
    redis.lpush(r, p <> "str", ["y"])
  let assert Error(ServerError(kind: "ERR", ..)) =
    redis.command(r, ["NOSUCHCOMMAND"])
  // The connection carries on after an error.
  assert redis.get(r, p <> "str") == Ok(Some("x"))
}

pub fn binary_values_test() {
  use r, p <- with_redis
  let bytes = <<0, 255, 13, 10, 128>>
  assert redis.command_bits(r, [<<"SET">>, <<p:utf8, "bin">>, bytes])
    == Ok(Status("OK"))
  assert redis.command_bits(r, [<<"GET">>, <<p:utf8, "bin">>])
    == Ok(Bulk(bytes))
  // A typed helper can't read it as text.
  let assert Error(redis.UnexpectedReply(Bulk(_))) = redis.get(r, p <> "bin")
  Nil
}

pub fn pipeline_test() {
  use r, p <- with_redis
  let assert Ok(Nil) = redis.set(r, p <> "str", "x")
  assert redis.pipeline(r, [
      ["SET", p <> "k", "1"],
      ["INCR", p <> "k"],
      ["LPUSH", p <> "str", "y"],
      ["GET", p <> "k"],
    ])
    == Ok([
      Ok(Status("OK")),
      Ok(Integer(2)),
      Error(ServerError(
        kind: "WRONGTYPE",
        message: "Operation against a key holding the wrong kind of value",
      )),
      Ok(Bulk(<<"2">>)),
    ])
}

pub fn many_callers_share_the_connections_test() {
  use r, p <- with_redis
  let done = process.new_subject()
  list.repeat(Nil, 200)
  |> list.each(fn(_) {
    process.spawn(fn() { process.send(done, redis.incr(r, p <> "count")) })
  })
  let results =
    list.repeat(Nil, 200)
    |> list.map(fn(_) {
      let assert Ok(result) = process.receive(done, 2000)
      result
    })
  let values = list.map(results, fn(r) { result.unwrap(r, -1) })
  // Every increment ran once, and each caller got its own reply.
  let expected =
    int.range(from: 200, to: 0, with: [], run: fn(acc, n) { [n, ..acc] })
  assert list.sort(values, int.compare) == expected
  assert redis.get(r, p <> "count") == Ok(Some("200"))
}

pub fn transaction_test() {
  use r, p <- with_redis
  let assert Ok(Nil) = redis.set(r, p <> "str", "x")
  assert redis.transaction(r, [
      ["INCR", p <> "t"],
      ["INCR", p <> "t"],
      ["LPUSH", p <> "str", "y"],
    ])
    == Ok([
      Ok(Integer(1)),
      Ok(Integer(2)),
      Error(ServerError(
        kind: "WRONGTYPE",
        message: "Operation against a key holding the wrong kind of value",
      )),
    ])
  // A command Redis refuses to queue aborts the whole transaction.
  let assert Error(ServerError(kind: "EXECABORT", ..)) =
    redis.transaction(r, [["INCR", p <> "t"], ["NOSUCHCOMMAND"]])
  assert redis.get(r, p <> "t") == Ok(Some("2"))
}

pub fn watch_test() {
  use r, p <- with_redis
  let key = p <> "balance"
  let assert Ok(Nil) = redis.set(r, key, "100")
  let spend = fn(tx) {
    use balance <- result.try(redis.get(tx, key))
    let balance = option.unwrap(balance, "0") |> int.parse |> result.unwrap(0)
    Ok([["SET", key, int.to_string(balance - 10)]])
  }
  assert redis.watch(r, [key], spend) == Ok(Some([Ok(Status("OK"))]))
  assert redis.get(r, key) == Ok(Some("90"))

  // Another client changes the key between WATCH and EXEC: nothing runs.
  let conflicted =
    redis.watch(r, [key], fn(tx) {
      let assert Ok(Nil) = redis.set(r, key, "500")
      spend(tx)
    })
  assert conflicted == Ok(None)
  assert redis.get(r, key) == Ok(Some("500"))
}

pub fn scan_and_eval_test() {
  use r, p <- with_redis
  list.each(["a", "b", "c"], fn(k) {
    let assert Ok(Nil) = redis.set(r, p <> "scan:" <> k, "1")
  })
  let keys = scan_all(r, 0, p <> "scan:*", [])
  assert list.sort(keys, string.compare)
    == [p <> "scan:a", p <> "scan:b", p <> "scan:c"]

  assert redis.eval(
      r,
      "return redis.call('INCRBY', KEYS[1], ARGV[1])",
      [
        p <> "lua",
      ],
      ["5"],
    )
    == Ok(Integer(5))
}

fn scan_all(r, cursor, pattern, acc) {
  let assert Ok(#(next, keys)) = redis.scan(r, cursor, Some(pattern))
  let acc = list.append(acc, keys)
  case next {
    0 -> acc
    _ -> scan_all(r, next, pattern, acc)
  }
}

pub fn pub_sub_test() {
  use r, p <- with_redis
  let inbox = process.new_subject()
  let assert Ok(subscription) =
    redis.subscribe(r, [p <> "news", p <> "other"], inbox)
  // Wait until the subscription is registered.
  wait_for_subscribers(r, p <> "news", 50)

  assert redis.publish(r, p <> "news", "hello") == Ok(1)
  assert process.receive(inbox, 1000)
    == Ok(Published(channel: p <> "news", payload: <<"hello">>))
  assert redis.publish(r, p <> "other", "two") == Ok(1)
  assert process.receive(inbox, 1000)
    == Ok(Published(channel: p <> "other", payload: <<"two">>))

  redis.unsubscribe(subscription)
  process.sleep(50)
  assert redis.publish(r, p <> "news", "gone") == Ok(0)
  assert process.receive(inbox, 100) == Error(Nil)
}

fn wait_for_subscribers(r, channel, tries) {
  case redis.command(r, ["PUBSUB", "NUMSUB", channel]), tries {
    Ok(Array([_, Integer(0)])), 0 -> panic as "never subscribed"
    Ok(Array([_, Integer(0)])), _ -> {
      process.sleep(10)
      wait_for_subscribers(r, channel, tries - 1)
    }
    _, _ -> Nil
  }
}

pub fn commands_are_traced_test() {
  case envoy.get("GLOSS_TEST_REDIS_URL") {
    Error(Nil) -> Nil
    Ok(url) -> {
      let spans = process.new_subject()
      let assert Ok(config) = redis.from_url(url)
      let assert Ok(r) =
        config
        |> redis.tracer(tracer.new() |> tracer.handle(process.send(spans, _)))
        |> redis.start
      let parent = tracer.root()
      tracer.with_current(parent, fn() {
        let _ = redis.get(r, "gloss-test:traced")
        let _ = redis.pipeline(r, [["PING"], ["GET", "x"]])
        let _ = redis.lpush(r, "gloss-test:traced-str", [])
        Nil
      })
      let assert Ok(tracer.Span(
        source: "gloss.redis",
        name: "get",
        meta:,
        error: None,
        trace:,
        parent_span_id: Some(parent_id),
        ..,
      )) = process.receive(spans, 1000)
      assert meta
        == [
          #("command", meta.String("GET")),
          #("key", meta.String("gloss-test:traced")),
        ]
      assert parent_id == parent.span_id
      assert trace.trace_id == parent.trace_id
      let assert Ok(tracer.Span(name: "pipeline", meta:, ..)) =
        process.receive(spans, 1000)
      assert meta
        == [
          #("commands", meta.Int(2)),
          #("command", meta.String("PING GET")),
        ]
      // LPUSH with no values is refused: the span records the error.
      let assert Ok(tracer.Span(name: "lpush", error: Some(_), ..)) =
        process.receive(spans, 1000)
      redis.shutdown(r)
    }
  }
}

pub fn reconnects_after_the_connection_drops_test() {
  use r, p <- with_redis
  let assert Ok(Nil) = redis.set(r, p <> "k", "v")
  // Another client kills every other connection, ours included.
  let assert Ok(url) = envoy.get("GLOSS_TEST_REDIS_URL")
  let assert Ok(config) = redis.from_url(url)
  let assert Ok(killer) = redis.start(config |> redis.pool_size(1))
  let assert Ok(Integer(killed)) =
    redis.command(killer, ["CLIENT", "KILL", "TYPE", "normal", "SKIPME", "yes"])
  assert killed >= 2
  redis.shutdown(killer)
  // Commands fail while it reconnects, then work again.
  assert eventually(fn() { redis.get(r, p <> "k") }, 50) == Ok(Some("v"))
}

fn eventually(f, tries) {
  case f(), tries {
    Ok(value), _ -> Ok(value)
    Error(error), 0 -> Error(error)
    Error(_), _ -> {
      process.sleep(20)
      eventually(f, tries - 1)
    }
  }
}

pub fn named_clients_test() {
  case envoy.get("GLOSS_TEST_REDIS_URL") {
    Error(Nil) -> Nil
    Ok(url) -> {
      let name = process.new_name("gloss_redis_test")
      let r = redis.from_name(name)
      assert redis.command(r, ["PING"]) == Error(redis.Unavailable)
      let assert Ok(config) = redis.from_url(url)
      let assert Ok(_) = config |> redis.named(name) |> redis.start
      assert redis.command(r, ["PING"]) == Ok(Status("PONG"))
      redis.shutdown(r)
    }
  }
}

pub fn auth_test() {
  case envoy.get("GLOSS_TEST_REDIS_AUTH_URL") {
    Error(Nil) -> Nil
    Ok(url) -> {
      let assert Ok(config) = redis.from_url(url)
      let assert Ok(r) = redis.start(config)
      assert redis.command(r, ["PING"]) == Ok(Status("PONG"))
      redis.shutdown(r)

      // A wrong password: the client starts, and commands say why.
      let assert Ok(r) = config |> redis.password(Some("wrong")) |> redis.start
      let assert Error(redis.ConnectionFailed(reason)) =
        redis.command(r, ["PING"])
      assert string.contains(reason, "WRONGPASS")
      redis.shutdown(r)

      // No password at all.
      let assert Ok(r) = config |> redis.password(None) |> redis.start
      let assert Error(ServerError(kind: "NOAUTH", ..)) =
        redis.command(r, ["PING"])
      redis.shutdown(r)
    }
  }
}

pub fn failed_replies_inside_arrays_test() {
  use r, p <- with_redis
  // An EVAL returning an error table inside an array.
  assert redis.eval(r, "return {1, redis.error_reply('BAD thing')}", [p], [])
    == Ok(Array([Integer(1), Failed(kind: "BAD", message: "thing")]))
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueOption)) -> Int

type UniqueOption {
  Positive
}

fn unique() -> Int {
  unique_integer([Positive])
}

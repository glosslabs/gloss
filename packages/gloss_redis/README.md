# gloss_redis

A [Redis](https://redis.io) client for gloss. It speaks RESP2 over TCP or TLS
itself, with no other client underneath: pooled and pipelined connections,
typed helpers for the common commands, transactions, pub/sub, and a tracer
span per command.

```gleam
import gleam/option.{Some}
import gloss/redis

let assert Ok(config) = redis.from_url("redis://:secret@localhost:6379/0")
let assert Ok(r) = config |> redis.tracer(tracer) |> redis.start

let assert Ok(Nil) = redis.set(r, "greeting", "hello")
let assert Ok(Some("hello")) = redis.get(r, "greeting")
let assert Ok(3) = redis.incr_by(r, "visits", 3)

// Anything else, by name:
redis.command(r, ["ZADD", "scores", "10", "ada"])
```

## Configuration

`redis.new()` is `localhost:6379`, database 0. `redis.from_url` reads
`redis://[[user]:password@]host[:port][/database]`, or `rediss://` for TLS
(the server's certificate must chain to a system CA and match the host).

| Setter | Default | |
|---|---|---|
| `host`, `port` | `localhost`, `6379` | |
| `tls` | `False` | |
| `password`, `username` | none | `AUTH` with a password, or an ACL user and password |
| `database` | 0 | `SELECT`ed on every connection |
| `pool_size` | 2 | Connections commands are shared between |
| `timeout` | 5 seconds | How long a call waits for its reply, and for connecting |
| `tracer` | none | |
| `named` | none | Register the client so `from_name` reaches it across restarts |

`start` starts the client linked to the caller; `supervised` returns a child
specification for `gleam/otp`. `shutdown` closes every connection.

## Connections

Each connection is a process that writes requests as they arrive and matches
replies in order, so callers never wait for a free connection: commands from
many processes are pipelined over the same few sockets. Calls are spread over
the pool in turn, and each waits up to `timeout` for its reply.

A connection that drops reconnects with backoff, from 100 milliseconds up to
5 seconds. Commands in flight when it drops fail with `ConnectionLost` (they
may or may not have run); commands while it is down fail at once with
`ConnectionFailed` instead of waiting. `start` succeeds even when Redis is
down, so an application can boot without it and recover when it returns.

## Commands

| Function | Redis |
|---|---|
| `get`, `set`, `set_with` (expiry, `IfMissing`/`IfExists`) | `GET`, `SET … PX … NX/XX` |
| `del`, `exists`, `expire`, `ttl` | `DEL`, `EXISTS`, `PEXPIRE`, `PTTL` |
| `incr`, `incr_by`, `mget` | `INCRBY`, `MGET` |
| `hset`, `hget`, `hgetall`, `hdel` | hashes |
| `lpush`, `rpush`, `lpop`, `rpop`, `lrange` | lists |
| `sadd`, `srem`, `smembers` | sets |
| `scan` | one `SCAN` step, with an optional `MATCH` pattern |
| `eval` | `EVAL` |
| `publish` | `PUBLISH` |
| `command`, `command_bits` | anything, returning a `Reply` |

The typed helpers take and return `String`s. A stored value that isn't UTF-8
comes back as `UnexpectedReply(Bulk(bytes))`; use `command_bits` for binary
data, whose replies carry `Bulk(BitArray)`.

Errors from Redis are `ServerError(kind, message)`, where `kind` is the
error's first word: `ERR`, `WRONGTYPE`, `NOAUTH` and so on.

## Pipelines and transactions

`pipeline` sends several commands in one round trip, each with its own
result. `transaction` wraps them in `MULTI` and `EXEC`, so no other client's
commands run between them; a command Redis refuses to queue aborts it with
`ServerError("EXECABORT", …)`.

`watch` is optimistic locking: it `WATCH`es keys on a connection of its own,
lets you read through that connection, then runs the commands you return as a
transaction. It returns `Ok(None)` if a watched key changed meanwhile, so
nothing ran and you can try again.

```gleam
redis.watch(r, ["balance"], fn(tx) {
  use balance <- result.try(redis.get(tx, "balance"))
  let balance = option.unwrap(balance, "0") |> int.parse |> result.unwrap(0)
  Ok([["SET", "balance", int.to_string(balance - 10)]])
})
```

## Pub/sub

`subscribe` opens a connection of its own, linked to the caller, and sends
each message to a subject as `Published(channel, payload)`, with the payload
as a `BitArray`. If the connection drops it reconnects and subscribes again;
messages published meanwhile are missed, as Redis doesn't keep them.
`unsubscribe` closes it.

```gleam
let inbox = process.new_subject()
let assert Ok(subscription) = redis.subscribe(r, ["news"], inbox)
let assert Ok(1) = redis.publish(r, "news", "hello")
let assert Ok(redis.Published("news", <<"hello">>)) = process.receive(inbox, 1000)
redis.unsubscribe(subscription)
```

## Tracing

Each command is a span from source `gloss.redis`, named after the command in
lower case (`get`), with `command` and, for commands that take one, `key` in
its meta. Values are never recorded. A pipeline or transaction is one span,
with `commands` (how many) and their names. Failed commands set the span's
error. Spans are children of the caller's current span (`tracer.current`),
so commands made while handling a request appear in its trace.

## Not supported yet

RESP3 (`HELLO 3`), pattern subscriptions (`PSUBSCRIBE`), Redis Cluster and
Sentinel, and client-side caching.

## Tests

The integration tests run against a real Redis when `GLOSS_TEST_REDIS_URL`
is set, and the `AUTH` test when `GLOSS_TEST_REDIS_AUTH_URL` is too:

```sh
docker run -d -p 6390:6379 redis:7
docker run -d -p 6391:6379 redis:7 redis-server --requirepass s3cret
GLOSS_TEST_REDIS_URL=redis://127.0.0.1:6390/0 \
GLOSS_TEST_REDIS_AUTH_URL=redis://:s3cret@127.0.0.1:6391/0 gleam test
```

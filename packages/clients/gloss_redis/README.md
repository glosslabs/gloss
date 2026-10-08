# gloss_redis

A Redis client speaking RESP directly: pooled, pipelined, with pub/sub and
tracing. Imported as `gloss/redis`.

```gleam
let assert Ok(config) = redis.from_url("redis://localhost:6379/0")
let assert Ok(r) = redis.start(config)

let assert Ok(Nil) = redis.set(r, "greeting", "hello")
redis.get(r, "greeting")  // -> Ok(Some("hello"))
```

- Typed helpers for strings, counters, expiry, hashes, lists and sets; `command` for anything else.
- `pipeline`, `transaction` (MULTI/EXEC), `watch`, and `subscribe`/`publish`.
- Its live tests run when `GLOSS_TEST_REDIS_URL` is set (and `GLOSS_TEST_REDIS_AUTH_URL` for a server with a password).

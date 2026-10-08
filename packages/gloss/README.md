# gloss

The core of gloss: an HTTP server and router, a database pool, tracing,
logging, a scheduler and the pieces around them, built only on the gleam-lang
packages.

```gleam
import gleam/erlang/process
import gloss/http/context
import gloss/http/reply
import gloss/http/router
import gloss/http/server

pub fn main() {
  let routes =
    router.new()
    |> router.get("/notes/:id", fn(_req, ctx) {
      use id <- context.int_param(ctx, "id")
      reply.json(200, note_json(find(ctx.state, id)))
    })

  let assert Ok(_) = server.new(routes, state) |> server.port(4000) |> server.start
  process.sleep_forever()
}
```

| Modules | |
|---|---|
| `gloss/http/server`, `router`, `context`, `reply` | The HTTP/1.1 server, routing, handlers and responses |
| `gloss/http/body`, `query`, `multipart`, `upload` | Reading requests: JSON, forms, query strings, streamed uploads |
| `gloss/http/session`, `session/memory`, `session/file`, `cookie` | Server-side sessions and cookies |
| `gloss/http/csrf`, `cors`, `secure_headers` | Protection middleware |
| `gloss/http/static`, `compress`, `sse`, `websocket` | Files, gzip, server-sent events, WebSockets |
| `gloss/http/traceparent`, `debug_bar` | W3C trace context; a development panel for each page |
| `gloss/store` | Storage messages answered by a database or memory adapter |
| `gloss/tracer`, `logger`, `logger/file`, `meta` | Spans and points; structured logging |
| `gloss/scheduler` | Interval and cron tasks |
| `gloss/clock`, `id` | Time and ids as values, so tests can control them |
| `gloss/password`, `signal`, `reload` | Password hashing; graceful shutdown; development reloading |

Each module's documentation has the details.

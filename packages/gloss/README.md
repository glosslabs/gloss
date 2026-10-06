# gloss

The core of gloss: an HTTP server and router, tracing, logging, a
scheduler and signal handling, with no dependencies beyond the gleam-lang
packages.

| Module | |
|---|---|
| `gloss/http/*` | HTTP/1.1 server, router, request context, replies and body decoding |
| `gloss/tracer` | Spans and points, delivered to handlers you attach |
| `gloss/logger` | Structured logging with channels (`stdout`, `stderr`, `otp`, `memory`, …), `min_level`/`max_level` to split them |
| `gloss/logger/file` | A log channel that appends to a file and rotates it by size |
| `gloss/meta` | Key/value metadata shared by the tracer and logger |
| `gloss/scheduler` | Interval and cron tasks |
| `gloss/signal` | SIGTERM/SIGHUP delivery for graceful shutdown |

## HTTP

```gleam
import gloss/signal
import gloss/http/router
import gloss/http/server

pub fn routes() -> Router(App) {
  let public =
    router.new()
    |> router.get("/health", health.show)

  let notes =
    router.group("/notes")
    |> router.with(auth.authenticate)
    |> router.get("/", notes.index)
    |> router.get("/:id", notes.show)

  router.combine([public, notes])
}

pub fn main() {
  let assert Ok(srv) =
    server.new(routes(), state)
    |> server.port(4000)
    |> server.tracer(tracer)
    |> server.logger(log)
    |> server.start

  signal.wait_for_terminate()
  let _ = server.shutdown(srv)
}
```

Handlers live in their own modules and take the request and a `Context`:

```gleam
pub fn show(_req: Request, ctx: Context(App)) -> Response {
  use id <- context.int_param(ctx, "id")
  case notes.get(ctx.state.notes, id) {
    Ok(note) -> reply.json(200, note_json(note))
    Error(Nil) -> reply.not_found()
  }
}
```

### Modules

| Module | |
|---|---|
| `gloss/http/server` | Builder (`new`, `port`, `bind`, `tracer`, `logger`, `with`, limits), `start`, `supervised`, `shutdown`, and `handle` for tests |
| `gloss/http/router` | `group`, `with`, `get`/`post`/…, `combine`, `check`, `describe`, `inspect`, `allowed_methods` |
| `gloss/http/context` | `Context(state)`, `Handler`, `Middleware`, `param`/`int_param` |
| `gloss/http/reply` | `Request`/`Response`/`Body` types, `json`, `text`, `html`, `bytes`, `stream`, `empty`, error replies (`error`, `problem`, `not_found`, …), `preferred` |
| `gloss/http/body` | `json(req, decoder, next)` and `text(req, next)` |
| `gloss/http/cookie` | `get`, `all`, `set`, `delete`, with secure `defaults()` |
| `gloss/http/session` | Server-side sessions: `load`, `get`/`set`/`remove`, `save`, `regenerate`, `destroy`, over a pluggable `Store` |
| `gloss/http/session/memory` | The default store: an ETS table swept of expired sessions every minute |
| `gloss/http/csrf` | Cross-site request forgery protection from `Sec-Fetch-Site` and `Origin`, with no tokens |
| `gloss/http/static` | Files from a directory via `sendfile`, with content types, ETag revalidation and `cache-control` |
| `gloss/http/sse` | Server-sent events over a streamed response |
| `gloss/http/websocket` | WebSocket upgrades: `on_init`/`on_message`/`on_close`, `send_text`/`send_binary`, messages from other processes |

### Errors follow the `Accept` header

`reply.error`, `reply.problem` and the shortcuts (`not_found`,
`bad_request`, `unprocessable`, …) carry a message and optional details
rather than a rendered body. The server renders them, and its own 404,
405, 413 and 500 responses, in the format the request's `Accept` header
prefers:

| Media type | Body |
|---|---|
| `application/json` | `{"error": "not found"}`, plus `"errors": [...]` when there are details |
| `application/problem+json` | RFC 9457 `type`, `title`, `status`, `detail` |
| `text/html` | an error page: `reply.default_error_page`, or your own via `server.error_page` |
| `text/plain` | the message, then one detail per line |

JSON is the default when there is no `Accept` header, for `*/*`, and when
nothing offered is acceptable. Handlers that serve several formats
themselves can ask `reply.preferred(req, ["application/json", "text/html"])`.

```gleam
server.new(routes(), state)
|> server.error_page(fn(page) { layout.error(page.status, page.title, page.message) })
```

### Logging, tracing and Sentry

Every request produces one `tracer.Span` from source `"gloss.http"`, named
after its route (`"GET /notes/:id"`), with method, path, route, status,
request id and size in its meta. A panic or 5xx status marks the span as
failed. Wire the tracer once and the rest follows:

```gleam
tracer.new()
|> tracer.handle(logger.trace_handler(log))      // access log
|> tracer.handle(gloss_sentry.handler(sentry))   // failed requests to Sentry
```

Handlers get `ctx.log`, the server's logger with `request_id` and `route`
added to every entry.

### Graceful shutdown

`server.shutdown` stops accepting connections, closes idle keep-alive
connections, lets in-flight requests finish (answering them with
`connection: close`), and returns once all are done, or with
`TimedOut(n)` after `shutdown_timeout`. A server started with
`server.supervised` drains the same way when its supervisor stops it.
`gloss/signal.wait_for_terminate` blocks until SIGTERM, so `main` can shut
down cleanly under Docker, systemd or Kubernetes. Ctrl-C (SIGINT) cannot be
caught by the BEAM and stops the node immediately.

### Limits

HTTP/1.1 only, without TLS: run behind a proxy that terminates it. Request
bodies may be sent with `Content-Length` or chunked, and are read in full
up to `max_body`. Responses can be streamed with `reply.stream` (chunked
for HTTP/1.1), and upgraded to WebSockets with `gloss/http/websocket`.

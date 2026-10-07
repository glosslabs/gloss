# gloss

The core of gloss: an HTTP server and router, a database layer, tracing,
logging, a scheduler and signal handling, with no dependencies beyond the
gleam-lang packages.

| Module | |
|---|---|
| `gloss/http/*` | HTTP/1.1 server, router, request context, replies and body decoding |
| `gloss/sql` | Statements, row decoding, transactions and a connection pool, shared by every database driver |
| `gloss/tracer` | Spans and points, delivered to handlers you attach |
| `gloss/logger` | Structured logging with channels (`stdout`, `stderr`, `otp`, `memory`, …), `min_level`/`max_level` to split them |
| `gloss/logger/file` | A log channel that appends to a file and rotates it by size |
| `gloss/meta` | Key/value metadata shared by the tracer and logger |
| `gloss/scheduler` | Interval and cron tasks |
| `gloss/signal` | SIGTERM/SIGHUP delivery for graceful shutdown |
| `gloss/password` | Password hashing (salted PBKDF2-SHA256) and constant-time verification |

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

### Application state

`server.new(routes, state)` takes the application's own services (its
domain modules and their stores), which handlers reach as `ctx.state`. The
server's infrastructure stays out of it and sits beside it on the context:
`ctx.log`, `ctx.tracer` and `ctx.sessions` (given with `server.logger`,
`server.tracer` and `server.sessions`). One state is the simple case;
larger apps can give separate route groups their own state.

### Modules

| Module | |
|---|---|
| `gloss/http/server` | Builder (`new`, `port`, `bind`, `tracer`, `logger`, `with`, `trust_proxies`, `request_timeout`, `max_connections`, limits), `start`, `supervised`, `shutdown`, and `handle` for tests |
| `gloss/http/router` | `group`, `with`, `get`/`post`/…, `combine`, `check`, `describe`, `inspect`, `allowed_methods` |
| `gloss/http/context` | `Context(state)`, `Handler`, `Middleware`, `param`/`int_param` |
| `gloss/http/reply` | `Request`/`Response`/`Body` types, `json`, `text`, `html`, `bytes`, `stream`, `empty`, error replies (`error`, `problem`, `not_found`, …), `preferred` |
| `gloss/http/body` | Read bodies on demand: `json`, `text`, `bits`, `form` (urlencoded or multipart; up to `max_body`), or `stream`/`fold` for large uploads; gzipped bodies are inflated |
| `gloss/http/multipart` | Stream `multipart/form-data` uploads part by part |
| `gloss/http/upload` | Save an uploaded file to disk as it arrives, with type and size limits |
| `gloss/http/query` | Query parameters: `get`, `get_all`, `all`, and `string`/`int`/`optional_int` that answer `400` |
| `gloss/http/cors` | Cross-origin resource sharing middleware, with preflight handling |
| `gloss/http/cookie` | `get`, `all`, `set`, `delete`, with secure `defaults()` |
| `gloss/http/session` | Server-side sessions: `load`, `get`/`set`/`remove`, `save`, `regenerate`, `destroy`, over a pluggable `Store` |
| `gloss/http/session/memory` | The default store: an ETS table swept of expired sessions every minute |
| `gloss/http/csrf` | Cross-site request forgery protection from `Sec-Fetch-Site` and `Origin`, with no tokens |
| `gloss/http/static` | Files from a directory via `sendfile`, with content types, ETag revalidation, byte ranges (including multipart) for media, pre-compressed `.br`/`.gz` copies, and `cache-control` |
| `gloss/http/sse` | Server-sent events over a streamed response |
| `gloss/http/compress` | gzip middleware for JSON, text and streamed responses, by `accept-encoding` |
| `gloss/http/websocket` | WebSocket upgrades: `on_init`/`on_message`/`on_close`, `send_text`/`send_binary`, messages from other processes |
| `gloss/http/traceparent` | W3C Trace Context: continue or start a trace per request (`ctx.trace`), and propagate it to downstream calls |

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
request id and size in its meta. Its `trace` and `parent_span_id` fields
place it in the W3C trace the request belongs to. A panic or 5xx status marks the span as
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

HTTP/1.1 only, without TLS: run behind a reverse proxy that terminates it,
and list it in `server.trust_proxies` so `ctx.client_ip`, `req.scheme` and
`req.host` describe the client rather than the proxy. Request
bodies may be sent with `Content-Length` or chunked. They are read only when
a handler asks: in full up to `max_body` (`body.bits`/`text`/`json`), or
streamed piece by piece for large uploads (`body.stream`). Responses can be streamed with `reply.stream` (chunked
for HTTP/1.1), and upgraded to WebSockets with `gloss/http/websocket`.

## Database

`gloss/sql` is the database API: one `Db` handle, statements with typed
row decoders, transactions and a connection pool. A driver does the
database-specific work: `gloss/pg`, from the [`gloss_pg`](../gloss_pg)
package, is the first.

```gleam
import gleam/dynamic/decode
import gloss/pg
import gloss/sql

let assert Ok(config) = pg.from_url("postgres://app:secret@localhost/app")
let assert Ok(db) =
  sql.new(pg.driver(config))
  |> sql.pool_size(10)
  |> sql.tracer(tracer)
  |> sql.start

let user = {
  use id <- decode.field(0, decode.int)
  use email <- decode.field(1, decode.string)
  decode.success(User(id:, email:))
}

sql.query("select id, email from users where id = $1")
|> sql.bind(sql.Int(id))
|> sql.returning(user)
|> sql.one(db, _)
```

`sql.all`, `sql.one`, `sql.optional` and `sql.exec` run a statement for
its rows, its only row, an optional row, or the count of affected rows.
`sql.script` runs SQL text holding several statements, such as a schema.
Statements can also be built from parts, with placeholders numbered for
you:

```gleam
sql.query("select id, email from users where deleted_at is null")
|> sql.when(status, fn(s, status) {
  s |> sql.append(" and status = ") |> sql.arg(sql.Text(status))
})
|> sql.append(" order by id limit ")
|> sql.arg(sql.Int(limit))
```

`sql.transaction(db, fn(tx) { ... })` commits when the body returns `Ok`,
rolls back on `Error` or a panic, and turns nested transactions into
savepoints. Errors are one `sql.Error` type for every driver, with
`UniqueViolation`, `ForeignKeyViolation`, `NotNullViolation` and
`CheckViolation` broken out so callers can match on them.

### The pool

Connections open on demand, up to `pool_size`, in helper processes so a
slow connect never blocks other callers. A statement borrows a connection
and runs on it in the caller's process, so rows never pass through the
pool. A process that dies holding a connection has it closed rather than
reused. Use `sql.supervised(builder)` in a supervision tree and
`sql.db(builder)` for the handle; it works across pool restarts.

Every statement is a `tracer.Span` from source `"gloss.sql"`, and
transactions are spans whose statements are their children.
`sql.child_of(db, traceparent.span_context(ctx.trace))` puts a request's
statements in the request's trace.

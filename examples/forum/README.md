# forum

A small server-rendered forum built with `gloss/http` and
[Lustre](https://hexdocs.pm/lustre): register and sign in with an email and
password, edit your profile and upload an avatar, start threads and reply to
them. Readers with a thread open see new replies arrive over a WebSocket
(`/threads/:id/live`, appended by `priv/static/live.js`). It exists to exercise gloss's HTTP and database features; styling is
minimal. Users, threads and posts are stored in Postgres through
`gloss/sql` and `gloss/pg`, and avatars on disk.

```sh
mise run db             # Postgres 18 in Docker, from compose.yaml
mise run dev            # listens on :4000, creating the tables it needs
open http://localhost:4000
```

| Variable | Default | |
|---|---|---|
| `PORT` | `4000` | |
| `APP_ENV` | `development` | Outside `development` the session cookie is `Secure` |
| `DATA_DIR` | `data` | Avatars are written to `DATA_DIR/avatars` |
| `LOG_DIR` | `log` | Where `app.log` (debug, info) and `error.log` (warnings, errors) are written; each rotates at 10 MB, keeping 5 |
| `SENTRY_DSN` | unset | Report failed requests and error events to Sentry |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | Export traces and logs to OpenTelemetry, e.g. `http://localhost:4318` |
| `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/forum` | The Postgres database |

## Layout

The core of the application is separate from the web server and from
outside services. `domain/` knows nothing of HTTP, HTML, SQL or Sentry;
`server/` and `store/` depend on it, never the reverse. `app/` starts the
outside services (logging, Sentry, the database) and composes everything.

| Module | |
|---|---|
| `app` | `main`: composes config, logging, tracing, the domain services and the server |
| `app/config` | Settings from the environment |
| `app/logging`, `app/tracing` | Where log entries go (console and rotated files); where trace events go (the log, Sentry and OpenTelemetry) |
| `app/debug` | In development (`APP_ENV`): the debug bar at the foot of each page, and reloading code and pages when `src` or `priv` changes |
| `app/otel` | The OpenTelemetry exporter, started when `OTEL_EXPORTER_OTLP_ENDPOINT` is set |
| `app/sentry` | The Sentry client, started when `SENTRY_DSN` is set |
| `app/db` | The Postgres connection pool, and the schema it creates at start |
| `domain/accounts` | Registration, sign-in, profiles and avatars |
| `domain/accounts/user` | User rules; passwords are hashed with `gloss/password` |
| `domain/accounts/user_store` | The port for storing users: the messages a user store answers |
| `domain/forum` | Threads and replies |
| `domain/forum/thread` | Thread and post rules |
| `domain/forum/thread_store` | The port for storing threads and posts |
| `server` | The HTTP server: routes, CSRF protection, compression, error pages |
| `server/state` | What handlers reach through `ctx.state`, including the signed-in user |
| `server/routing` | The route table, and nothing else |
| `server/handlers/*` | One module per area: accounts, threads, profile, users |
| `server/middleware/current_user` | The signed-in user from the session |
| `server/views/*` | Lustre views rendered to HTML |
| `store/users`, `store/threads` | The stores, answered from Postgres |
| `store/schema/*` | Each table's columns, for `gloss/sql/query` |

### Domains and stores

Each domain (`accounts`, `forum`) stands alone: it imports nothing from
another domain, and refers to users from the forum only by id.

Each aggregate has a store port in its domain: a message type, such as
`user_store.Message` (`Insert`, `Get`, `FindByEmail`, `Save`, ...), that a
store process answers, built on `gloss/store`. The domain services keep the
rules (validating input, hashing passwords, deciding timestamps) and send
messages for storage. `store/users` and `store/threads` answer them
with queries built by `gloss/sql/query` from a `store.inline` store, which runs in the calling process:
the pool already runs statements in parallel, and nothing is copied
between processes. The tests answer the same
messages from memory with `store.serial` (`test/support/memory_*`), and
`test/support/store_contract` checks that both behave the same.

Storage failing (the database being down) is not a domain outcome:
`store.call` panics, the server answers `500` and the failure reaches the
log and Sentry. Business outcomes, such as an email being taken, are part of
each message's answer.

## What it exercises

- Forms (`body.form`), with validation errors re-rendered as `422` and
  successful posts redirected with `303`.
- Server-side sessions (`gloss/http/session`), regenerated at sign-in.
- CSRF protection (`gloss/http/csrf`).
- Avatar uploads saved by `gloss/http/upload`, streamed straight to disk
  and checked for type (`415`) and size (`413`) as they arrive.
- Static files for CSS and avatars (`gloss/http/static`), and gzip
  (`gloss/http/compress`).
- Query parameters for paging (`gloss/http/query`).
- HTML error pages (`server.error_page`).
- Postgres through `gloss/sql` and `gloss/pg`: queries built with
  `gloss/sql/query` from typed table modules, `RETURNING`, transactions,
  unique-violation mapping, and a span per statement in the log.

`mise run test` runs the domain tests and the server tests, which drive the
whole app through `server.handle` like a browser keeping its session cookie,
on the in-memory stores. Set `TEST_DATABASE_URL` to also run the
store contract against Postgres; it empties the tables first, so give
it a database of its own.

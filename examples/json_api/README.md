# json_api

A small JSON API built with `gloss/http`: in-memory notes behind a bearer
token, with request logging, tracing and optional Sentry reporting.

```sh
mise run dev                    # listens on :4000
curl localhost:4000/health
curl -XPOST localhost:4000/notes \
  -H 'authorization: Bearer dev' \
  -H 'content-type: application/json' \
  -d '{"title": "milk"}'
curl -H 'authorization: Bearer dev' localhost:4000/notes
kill -TERM <pid>                # drains in-flight requests, then exits
```

Other tasks: `mise run test`, `mise run format`, and `mise run check`
(formatting, warnings-as-errors build and tests, as CI runs them).

| Variable | Default | |
|---|---|---|
| `PORT` | `4000` | |
| `API_TOKEN` | `dev` | Bearer token for `/auth` and `/notes` |
| `SENTRY_DSN` | unset | Report failed requests to Sentry |
| `APP_ENV` | `development` | Sentry environment |
| `LOG_DIR` | `log` | Where `app.log` (debug, info) and `error.log` (warnings, errors) are written; each rotates at 10 MB, keeping 5 |

## Layout

A minimal, progressive domain-driven layout: start with these modules and
add more as the application grows.

| Module | |
|---|---|
| `app` | `main`: composes the layers below, waits for SIGTERM, shuts down |
| `app/config` | Settings from the environment |
| `app/state` | `State`, what handlers reach through `ctx.state` |
| `app/notes` | The notes domain: an in-memory store |
| `app/reporters` | Where logs, traces and failures go: stdout/stderr and rotated files split by level, plus Sentry errors and logs when configured |
| `app/server` | The HTTP server: combines the route groups and starts serving |
| `app/routes/api` | The API's route table, and nothing else |
| `app/handlers/*` | One module per resource: `health`, `notes`, `users` |
| `app/middleware/*` | `auth`: bearer-token authentication |

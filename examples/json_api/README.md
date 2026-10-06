# json_api

A small JSON API built with `gloss/http`: in-memory notes behind a bearer
token, with request logging, tracing and optional Sentry reporting.

```sh
gleam run                       # listens on :4000
curl localhost:4000/health
curl -XPOST localhost:4000/notes \
  -H 'authorization: Bearer dev' \
  -H 'content-type: application/json' \
  -d '{"title": "milk"}'
curl -H 'authorization: Bearer dev' localhost:4000/notes
kill -TERM <pid>                # drains in-flight requests, then exits
```

| Variable | Default | |
|---|---|---|
| `PORT` | `4000` | |
| `API_TOKEN` | `dev` | Bearer token for `/auth` and `/notes` |
| `SENTRY_DSN` | unset | Report failed requests to Sentry |
| `APP_ENV` | `development` | Sentry environment |

## Layout

| Module | |
|---|---|
| `json_api` | `main`: composes the layers below, waits for SIGTERM, shuts down |
| `json_api/config` | Settings from the environment |
| `json_api/observability` | Logger and tracer, plus Sentry when configured |
| `json_api/app` | `App`, what handlers reach through `ctx.app` |
| `json_api/notes` | The in-memory store |
| `json_api/web` | The server builder |
| `json_api/web/routes` | The route table, and nothing else |
| `json_api/web/*` | Handlers and the `authenticate` middleware |

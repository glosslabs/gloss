# app

A Gloss application.

```sh
gleam run   # start the application
gleam test  # run the tests
```

## Configuration

| Variable | Purpose |
|---|---|
| `SENTRY_DSN` | Report failures to Sentry. Unset, nothing is sent. |
| `APP_ENV` | The Sentry environment. Defaults to `production`. |

Scheduled tasks are declared in `src/app/schedule.gleam`.

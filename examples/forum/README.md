# forum

A small server-rendered forum built with `gloss/http` and
[Lustre](https://hexdocs.pm/lustre): register and sign in with an email and
password, edit your profile and upload an avatar, start threads and reply to
them. It exists to exercise gloss's HTTP features; styling is minimal and
everything but avatars is kept in memory, so it resets on restart.

```sh
mise run dev            # listens on :4000
open http://localhost:4000
```

| Variable | Default | |
|---|---|---|
| `PORT` | `4000` | |
| `APP_ENV` | `development` | Outside `development` the session cookie is `Secure` |
| `DATA_DIR` | `data` | Avatars are written to `DATA_DIR/avatars` |

## Layout

The core of the application is separate from the web server. `domain/`
knows nothing of HTTP or HTML; `server/` depends on it, never the reverse.

| Module | |
|---|---|
| `app` | `main`: composes config, reporters, the domain services and the server |
| `app/config`, `app/reporters` | Settings from the environment; where logs and traces go |
| `domain/accounts` | Registration, sign-in, profiles and avatars |
| `domain/accounts/user`, `domain/accounts/password` | User rules; PBKDF2 password hashing |
| `domain/forum` | Threads and replies |
| `domain/forum/thread` | Thread and post rules |
| `server` | The HTTP server: routes, CSRF protection, compression, error pages |
| `server/state` | What handlers reach through `ctx.state`, including the signed-in user |
| `server/routes` | The route table, and nothing else |
| `server/handlers/*` | One module per area: accounts, threads, profile, users |
| `server/middleware/current_user` | The signed-in user from the session |
| `server/uploads` | Avatar uploads streamed straight to disk |
| `server/views/*` | Lustre views rendered to HTML |

## What it exercises

- Forms (`body.form`), with validation errors re-rendered as `422` and
  successful posts redirected with `303`.
- Server-side sessions (`gloss/http/session`), regenerated at sign-in.
- CSRF protection (`gloss/http/csrf`).
- Avatar uploads streamed with `gloss/http/multipart`, checked for type
  (`415`) and size (`413`) as they arrive.
- Static files for CSS and avatars (`gloss/http/static`), and gzip
  (`gloss/http/compress`).
- Query parameters for paging (`gloss/http/query`).
- HTML error pages (`server.error_page`).

`mise run test` runs the domain tests and the server tests, which drive the
whole app through `server.handle` like a browser keeping its session cookie.

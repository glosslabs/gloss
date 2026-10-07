# gloss_test

Test helpers for gloss applications. Add it as a dev dependency:

```toml
[dev_dependencies]
gloss_test = { path = "../gloss_test" }
```

| Module | |
|---|---|
| `gloss/testing/request` | Requests: `get`, `post`, `put`, `patch`, `delete` (paths may carry a query), `header`, `cookie`, `form`, `json`, `bits`, `multipart` with `Field` and `File` parts |
| `gloss/testing/response` | Reading responses: `text`, `bits`, `json(decoder)`, `header`, `location`, `cookie`, `set_cookies` |
| `gloss/testing/browser` | A browser over `server.handle` that keeps cookies: `get`, `submit` (a form post), `send`, `follow`, `cookie`, `clear_cookies` |
| `gloss/testing/html` | `text` (what a reader sees) and `attribute_values`, without a full parser |
| `gloss/testing/websocket` | A WebSocket client for a running server: `connect`, `send_text`, `send_binary`, `send_ping`, `send_close`, raw `send_frame`, `receive` with a timeout, `wait_closed` |

```gleam
import gloss/http/server
import gloss/testing/browser
import gloss/testing/html
import gloss/testing/response

pub fn sign_in_test() {
  let ada = browser.new(server.handle(app.builder(), _))
  let res = browser.submit(ada, "/login", [#("email", "ada@x"), #("password", "pw")])
  assert response.location(res) == Ok("/")
  let page = browser.follow(ada, res) |> response.text |> html.text
  assert string.contains(page, "Sign out")
}
```

A browser asks for HTML and marks each request as same-origin, as a real
one does, unless the request sets those headers itself. Give each person in
a test their own browser over the same application.

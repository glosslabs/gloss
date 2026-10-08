# gloss_testing

Test helpers for gloss applications. Add it as a dev dependency.

```gleam
import gloss/testing/browser
import gloss/testing/response

pub fn sign_in_test() {
  let ada = browser.new(server.handle(app.builder(), _))
  let res = browser.submit(ada, "/login", [#("email", "ada@x"), #("password", "pw")])
  assert response.location(res) == Ok("/")
}
```

| Module | |
|---|---|
| `gloss/testing/request`, `response` | Build requests; read responses |
| `gloss/testing/browser` | A cookie-keeping browser over `server.handle` |
| `gloss/testing/html` | Read the text and attributes of HTML |
| `gloss/testing/websocket` | A WebSocket client for a running server |
| `gloss/testing/clock`, `ids` | A clock that moves only when told; ids that count up |

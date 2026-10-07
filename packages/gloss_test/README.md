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
| `gloss/testing/clock` | A clock that stands still until the test calls `advance` or `set`; `clock(time)` is the `gloss/clock.Clock` to give the code under test |
| `gloss/testing/ids` | Ids that count up: `sequential("user_")` gives `user_1`, `user_2`, …; `uuids()` gives UUID-shaped ones |
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

Code that reads the time or makes ids should take a `Clock` or `Ids` from
its builder rather than call the system itself. Tests then pass fakes:

```gleam
import gloss/testing/clock as test_clock

pub fn replies_are_stamped_test() {
  let time = test_clock.new(timestamp.from_unix_seconds(1_700_000_000))
  let forum = forum.new(memory_threads.start(), test_clock.clock(time))
  let assert Ok(opened) = forum.open_thread(forum, 1, "Hello", "First")
  test_clock.advance(time, duration.minutes(5))
  let assert Ok(replied) = forum.reply(forum, opened.id, 2, "Second")
  assert replied.last_activity == timestamp.from_unix_seconds(1_700_000_300)
}
```

A browser asks for HTML and marks each request as same-origin, as a real
one does, unless the request sets those headers itself. Give each person in
a test their own browser over the same application.

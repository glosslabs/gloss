import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import gloss/http/session.{type Store}
import gloss/http/session/file

/// A fresh file under build/ for one test, unique across runs.
fn scratch() -> String {
  "build/test-sessions/"
  <> int.to_string(system_time())
  <> "-"
  <> int.to_string(unique())
  <> "/sessions.dets"
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

fn in(seconds: Int) {
  timestamp.add(timestamp.system_time(), duration.seconds(seconds))
}

/// Run `f` with a store whose owner is killed afterwards, as when the node
/// stops.
fn with_store(path: String, f: fn(Store) -> Nil) -> Nil {
  let done = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(store) = file.start(path)
      f(store)
      process.send(done, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(done, 5000)
  process.kill(owner)
  // Let the store's table close.
  process.sleep(50)
}

pub fn sessions_survive_a_restart_test() {
  let path = scratch()
  with_store(path, fn(store) {
    store.save("kept", dict.from_list([#("user", "ada")]), in(60))
    store.save("dropped", dict.from_list([#("user", "bob")]), in(60))
    store.delete("dropped")
    store.save("stale", dict.from_list([#("user", "cy")]), in(-1))
  })

  let assert Ok(store) = file.start(path)
  store.load("kept", timestamp.system_time())
  |> should.equal(Ok(dict.from_list([#("user", "ada")])))
  store.load("dropped", timestamp.system_time()) |> should.equal(Error(Nil))
  store.load("stale", timestamp.system_time()) |> should.equal(Error(Nil))
}

pub fn unopenable_file_fails_to_start_test() {
  let path = scratch()
  // A directory where the file should be.
  let assert Ok(_) = file.start(path <> "/nested.dets")
  file.start(path) |> should.be_error
}

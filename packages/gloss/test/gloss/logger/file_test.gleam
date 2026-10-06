import gleam/erlang/process
import gleam/int
import gleam/string
import gleeunit/should
import gloss/logger
import gloss/logger/file

/// A fresh directory under build/ for one test, unique across runs.
fn scratch() -> String {
  "build/test-logs/"
  <> int.to_string(system_time())
  <> "-"
  <> int.to_string(unique())
  <> "/"
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn sync() -> Nil {
  // Writes are asynchronous; give the writer a moment.
  process.sleep(50)
}

pub fn writes_formatted_lines_test() {
  let path = scratch() <> "nested/app.log"
  let assert Ok(log) =
    file.config(path)
    |> file.format(fn(entry) {
      logger.level_to_string(entry.level) <> " " <> entry.message
    })
    |> file.start
  log.info("one", [])
  log.error("two", [])
  sync()
  read(path) |> should.equal(Ok("info one\nerror two\n"))
}

pub fn appends_to_an_existing_file_test() {
  let path = scratch() <> "app.log"
  let format = fn(entry: logger.Entry) { entry.message }
  let assert Ok(first) = file.config(path) |> file.format(format) |> file.start
  first.info("a", [])
  sync()
  let assert Ok(second) = file.config(path) |> file.format(format) |> file.start
  second.info("b", [])
  sync()
  read(path) |> should.equal(Ok("a\nb\n"))
}

pub fn rotates_by_size_and_keeps_old_files_test() {
  let path = scratch() <> "app.log"
  let assert Ok(log) =
    file.config(path)
    |> file.format(fn(entry) { entry.message })
    // Each line is 5 bytes ("1234\n"), so two fit per file.
    |> file.max_bytes(10)
    |> file.keep(2)
    |> file.start
  ["aaaa", "bbbb", "cccc", "dddd", "eeee", "ffff", "gggg"]
  |> each(log.info(_, []))
  sync()
  read(path) |> should.equal(Ok("gggg\n"))
  read(path <> ".1") |> should.equal(Ok("eeee\nffff\n"))
  read(path <> ".2") |> should.equal(Ok("cccc\ndddd\n"))
  read(path <> ".3") |> should.equal(Error(Nil))
}

pub fn unopenable_path_is_an_error_test() {
  let dir = scratch()
  let blocker = dir <> "blocker"
  // A file where a directory is needed makes the open fail.
  let assert Ok(log) = file.config(blocker) |> file.start
  log.info("x", [])
  sync()
  let assert Error(file.CannotOpen(path:, ..)) =
    file.config(blocker <> "/app.log") |> file.start
  string.ends_with(path, "blocker/app.log") |> should.be_true
}

fn each(items: List(a), f: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [x, ..rest] -> {
      f(x)
      each(rest, f)
    }
  }
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueOption)) -> Int

type UniqueOption {
  Positive
}

fn unique() -> Int {
  unique_integer([Positive])
}

@external(erlang, "file_test_ffi", "read")
fn read(path: String) -> Result(String, Nil)

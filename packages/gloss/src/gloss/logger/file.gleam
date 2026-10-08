//// A log channel that appends one line per entry to a file, rotating it by
//// size.
////
//// ```gleam
//// let assert Ok(errors) =
////   file.config("log/error.log")
////   |> file.max_bytes(10_000_000)
////   |> file.keep(5)
////   |> file.start
//// let log = logger.stack([logger.stderr(), errors])
//// ```
////
//// Writing happens in a process that owns the file, so the returned
//// `Logger` costs one message send per entry and never blocks. Missing
//// directories are created. Before a write would take the file past
//// `max_bytes`, it is renamed to `path.1` (older files shift to `path.2`
//// and so on, and the oldest beyond `keep` is deleted) and a new file is
//// started. Entries queued when the node stops are lost.
////
//// ## Supervision
////
//// `supervised` returns a child specification. Pair it with `named` and
//// `from_name` so a logger built before the tree starts keeps working across
//// restarts.

import gleam/bit_array
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import gloss/internal/logger_file_rotation as rotation
import gloss/internal/runtime
import gloss/logger.{type Entry, type Logger}

pub opaque type Config {
  Config(
    path: String,
    max_bytes: Int,
    keep: Int,
    format: fn(Entry) -> String,
    name: Option(Name(Message)),
  )
}

/// Messages the writer process understands. Exposed so a
/// `process.Name(Message)` can be created for `named`.
pub opaque type Message {
  Write(Entry)
  Stop
}

pub type StartError {
  /// The file could not be opened, e.g. `"eacces"`.
  CannotOpen(path: String, reason: String)
  Unavailable(reason: String)
}

/// Defaults: rotate at 10 MB, keep 5 old files, `logger.format` lines.
pub fn config(path: String) -> Config {
  Config(
    path:,
    max_bytes: 10_000_000,
    keep: 5,
    format: logger.format,
    name: None,
  )
}

/// Rotate before the file would grow past this many bytes.
pub fn max_bytes(config: Config, bytes: Int) -> Config {
  Config(..config, max_bytes: bytes)
}

/// How many rotated files to keep. `0` truncates on rotation.
pub fn keep(config: Config, count: Int) -> Config {
  Config(..config, keep: count)
}

/// How each entry becomes a line, e.g. JSON. A newline is added.
pub fn format(config: Config, format: fn(Entry) -> String) -> Config {
  Config(..config, format:)
}

/// Register the writer under `name`, so `from_name` reaches it across
/// restarts.
pub fn named(config: Config, name: Name(Message)) -> Config {
  Config(..config, name: Some(name))
}

/// Start the writer outside a supervision tree, linked to the caller.
pub fn start(config: Config) -> Result(Logger, StartError) {
  case start_actor(config) {
    Ok(started) -> Ok(started.data)
    Error(actor.InitFailed(reason)) ->
      Error(CannotOpen(path: config.path, reason:))
    Error(error) -> Error(Unavailable(string.inspect(error)))
  }
}

/// A child for a supervision tree.
pub fn supervised(config: Config) -> ChildSpecification(Logger) {
  supervision.worker(fn() { start_actor(config) })
}

/// A logger for a writer configured with `named`. Usable before the writer
/// starts; entries are dropped while it is not running.
pub fn from_name(name: Name(Message)) -> Logger {
  to_logger(process.named_subject(name))
}

/// Stop a writer started with `named`, closing its file. Entries already
/// queued are written first.
pub fn stop(name: Name(Message)) -> Nil {
  try_send(process.named_subject(name), Stop)
}

fn to_logger(subject: Subject(Message)) -> Logger {
  logger.new(fn(entry) { try_send(subject, Write(entry)) })
}

type State {
  /// `device` is `None` after a failed open; the next write tries again.
  State(config: Config, device: Option(Device), size: Int)
}

type Device

fn start_actor(
  config: Config,
) -> Result(actor.Started(Logger), actor.StartError) {
  let builder =
    actor.new_with_initialiser(1000, fn(subject) {
      use device <- result.map(open(config.path))
      State(config:, device: Some(device), size: file_size(config.path))
      |> actor.initialised
      |> actor.returning(to_logger(subject))
    })
    |> actor.on_message(on_message)
  case config.name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
  |> actor.start
}

fn on_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Stop -> {
      option.map(state.device, close)
      actor.stop()
    }
    Write(entry) -> {
      let line = bit_array.from_string(state.config.format(entry) <> "\n")
      let bytes = bit_array.byte_size(line)
      let state = case
        rotation.needed(
          size: state.size,
          incoming: bytes,
          max_bytes: state.config.max_bytes,
        )
      {
        True -> rotate(state)
        False -> state
      }
      let state = reopen(state)
      // A failed write is dropped: a full disk may clear, and a log channel
      // must not take its callers down.
      case option.map(state.device, write(_, line)) {
        Some(Ok(Nil)) ->
          actor.continue(State(..state, size: state.size + bytes))
        _ -> actor.continue(state)
      }
    }
  }
}

fn rotate(state: State) -> State {
  option.map(state.device, close)
  let plan = rotation.plan(state.config.path, state.config.keep)
  list.each(plan.delete, delete)
  list.each(plan.rename, fn(step) { rename(step.0, step.1) })
  State(..state, device: None, size: 0)
}

fn reopen(state: State) -> State {
  case state.device {
    Some(_) -> state
    None ->
      case open(state.config.path) {
        Ok(device) ->
          State(
            ..state,
            device: Some(device),
            size: file_size(state.config.path),
          )
        Error(_) -> state
      }
  }
}

@external(erlang, "gloss@logger@file_ffi", "open")
fn open(path: String) -> Result(Device, String)

@external(erlang, "gloss@logger@file_ffi", "write")
fn write(device: Device, data: BitArray) -> Result(Nil, Nil)

@external(erlang, "gloss@logger@file_ffi", "close")
fn close(device: Device) -> Nil

@external(erlang, "gloss@logger@file_ffi", "size")
fn file_size(path: String) -> Int

@external(erlang, "gloss@logger@file_ffi", "rename")
fn rename(from: String, to: String) -> Nil

@external(erlang, "gloss@logger@file_ffi", "delete")
fn delete(path: String) -> Nil

/// Send, dropping the message if the receiver is gone.
fn try_send(subject: Subject(message), message: message) -> Nil {
  let _ = runtime.try_send(subject, message)
  Nil
}

//// Report gloss tracer failures and explicit captures to Sentry.
////
//// ```gleam
//// let assert Ok(sentry) =
////   gloss_sentry.config(dsn)
////   |> gloss_sentry.environment("production")
////   |> gloss_sentry.release("1.4.0")
////   |> gloss_sentry.start(httpc.send)
////
//// let tracer = tracer.new() |> tracer.handle(gloss_sentry.handler(sentry))
//// gloss_sentry.capture(sentry, "payment declined", [#("order", meta.String(id))])
//// ```
////
//// A failed `tracer.Span` becomes a Sentry exception grouped by its
//// `source.name`; an `Error` or `Warning` `tracer.Point` becomes a message
//// event; everything else the tracer sees is kept as a breadcrumb and
//// attached to the next event. `logger(sentry)` is a log channel that
//// sends entries to Sentry Logs. Sending happens in a separate process, so
//// the handler and `capture` cost one message send and never block.
////
//// ## Sending
////
//// `start` and `supervised` take the function that performs the HTTP POST,
//// typically `httpc.send`, so this package has no HTTP client dependency and
//// tests can record requests instead. One envelope is in flight at a time;
//// the rest wait in a bounded queue that drops its oldest entry when full.
//// A 429 or an `X-Sentry-Rate-Limits` header pauses sending for the time
//// Sentry asks, and events during the pause are dropped. A transport error
//// or 5xx pauses for five seconds. Nothing is retried, so memory stays
//// bounded whatever Sentry does.
////
//// ## Supervision
////
//// `supervised` returns a child specification. Pair it with `named` and
//// `from_name` so handlers built before the tree starts keep working across
//// restarts.

import gleam/bit_array
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{type Monitor, type Name, type Pid, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gloss/logger.{type Logger}
import gloss/meta.{type Meta}
import gloss/tracer
import gloss_sentry/internal/dsn.{type Dsn, type DsnError}
import gloss_sentry/internal/engine
import gloss_sentry/internal/envelope

/// Messages the sender process understands. Opaque to applications; it is
/// exposed so a `process.Name(Message)` can be created for `named`.
pub type Message =
  engine.Message

/// How to reach Sentry. Build one with `config` and the setters.
pub opaque type Config {
  Config(
    dsn: String,
    environment: String,
    release: String,
    server_name: Option(String),
    max_queue: Int,
    breadcrumbs: Int,
    name: Option(Name(Message)),
  )
}

/// Defaults: environment `production`, no release, this node's name as
/// `server_name`, a queue of 100 envelopes and 50 breadcrumbs.
pub fn config(dsn: String) -> Config {
  Config(
    dsn:,
    environment: "production",
    release: "",
    server_name: None,
    max_queue: 100,
    breadcrumbs: 50,
    name: None,
  )
}

pub fn environment(config: Config, environment: String) -> Config {
  Config(..config, environment:)
}

pub fn release(config: Config, release: String) -> Config {
  Config(..config, release:)
}

pub fn server_name(config: Config, server_name: String) -> Config {
  Config(..config, server_name: Some(server_name))
}

/// How many envelopes may wait to be posted before the oldest is dropped.
pub fn max_queue(config: Config, max_queue: Int) -> Config {
  Config(..config, max_queue:)
}

/// How many recent tracer events are attached to each error.
pub fn breadcrumbs(config: Config, breadcrumbs: Int) -> Config {
  Config(..config, breadcrumbs:)
}

/// Register the sender under `name`, so `from_name` reaches it across
/// restarts.
pub fn named(config: Config, name: Name(Message)) -> Config {
  Config(..config, name: Some(name))
}

/// A handle on a sender. Every operation is one message send.
pub opaque type Sentry {
  Sentry(subject: Subject(Message))
}

pub type StartError {
  InvalidDsn(DsnError)
  /// The sender process could not start.
  Unavailable(reason: String)
}

/// The function that performs the HTTP POST, e.g. `httpc.send`. It runs in
/// a helper process, never in the caller's.
pub type Send(error) =
  fn(Request(String)) -> Result(Response(String), error)

/// Start a sender outside a supervision tree.
pub fn start(config: Config, send: Send(e)) -> Result(Sentry, StartError) {
  use parsed <- result.try(
    dsn.parse(config.dsn) |> result.map_error(InvalidDsn),
  )
  case start_actor(config, parsed, send) {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(Unavailable(string.inspect(error)))
  }
}

/// A child for a supervision tree. An invalid DSN fails the start.
pub fn supervised(config: Config, send: Send(e)) -> ChildSpecification(Sentry) {
  supervision.worker(fn() {
    case dsn.parse(config.dsn) {
      Ok(parsed) -> start_actor(config, parsed, send)
      Error(error) ->
        Error(actor.InitFailed("invalid DSN: " <> string.inspect(error)))
    }
  })
}

/// A handle for a sender configured with `named`. Usable before the sender
/// starts; sends are dropped while it is not running.
pub fn from_name(name: Name(Message)) -> Sentry {
  Sentry(process.named_subject(name))
}

/// A tracer handler that forwards every event to Sentry.
pub fn handler(sentry: Sentry) -> tracer.Handler {
  fn(event) { try_send(sentry.subject, engine.Traced(event)) }
}

/// A log channel that sends entries to Sentry Logs. Entries are batched:
/// up to 100 go out together, at most five seconds after the first one
/// arrives. An entry's `trace_id` meta (or a 32-character `request_id`,
/// which gloss/http sets to the trace id) becomes its Sentry trace id, so a
/// request's logs are grouped together.
///
/// ```gleam
/// let log = logger.stack([logger.stderr(), gloss_sentry.logger(sentry)])
/// ```
pub fn logger(sentry: Sentry) -> Logger {
  logger.new(fn(entry) { try_send(sentry.subject, engine.Logged(entry)) })
}

/// Report a handled problem as an error-level message event.
pub fn capture(sentry: Sentry, message: String, meta: Meta) -> Nil {
  try_send(
    sentry.subject,
    engine.Captured(timestamp.system_time(), envelope.Message(message), meta),
  )
}

/// Report a handled failure as an exception event grouped by `error`.
pub fn capture_error(sentry: Sentry, error: String, meta: Meta) -> Nil {
  let body =
    envelope.Exception(
      type_: "error",
      value: error,
      frames: [],
      mechanism: "generic",
      handled: True,
    )
  try_send(sentry.subject, engine.Captured(timestamp.system_time(), body, meta))
}

/// Stop the sender. Queued envelopes are dropped.
pub fn stop(sentry: Sentry) -> Nil {
  try_send(sentry.subject, engine.Stop)
}

type Shell {
  Shell(
    subject: Subject(Message),
    send: fn(Request(String)) -> Result(Response(String), String),
    /// The process posting the in-flight envelope, if any.
    poster: Option(#(Pid, Monitor)),
    state: engine.State,
  )
}

fn start_actor(
  config: Config,
  parsed: Dsn,
  send: Send(e),
) -> Result(actor.Started(Sentry), actor.StartError) {
  let settings =
    engine.Settings(
      dsn: parsed,
      environment: config.environment,
      release: config.release,
      server_name: option.unwrap(config.server_name, node_name()),
      max_queue: config.max_queue,
      breadcrumbs: config.breadcrumbs,
      trace_id: event_id(),
    )
  let send = fn(request) { send(request) |> result.map_error(string.inspect) }
  let builder =
    actor.new_with_initialiser(1000, fn(subject) {
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(engine.Down)
      Shell(subject:, send:, poster: None, state: engine.init(settings))
      |> actor.initialised
      |> actor.selecting(selector)
      |> actor.returning(Sentry(subject))
      |> Ok
    })
    |> actor.on_message(on_message)
  case config.name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
  |> actor.start
}

fn on_message(shell: Shell, message: Message) -> actor.Next(Shell, Message) {
  case message {
    engine.Stop -> actor.stop()
    engine.Down(process.ProcessDown(pid:, ..)) ->
      case shell.poster {
        Some(#(poster, _)) if poster == pid -> step(shell, message)
        _ -> actor.continue(shell)
      }
    engine.Down(process.PortDown(..)) -> actor.continue(shell)
    engine.Posted(_) -> {
      case shell.poster {
        Some(#(_, monitor)) -> process.demonitor_process(monitor)
        None -> Nil
      }
      step(Shell(..shell, poster: None), message)
    }
    _ -> step(shell, message)
  }
}

fn step(shell: Shell, message: Message) -> actor.Next(Shell, Message) {
  let #(state, effects) =
    engine.handle(shell.state, message, timestamp.system_time(), event_id)
  list.fold(effects, Shell(..shell, state:), perform)
  |> actor.continue
}

fn perform(shell: Shell, effect: engine.Effect) -> Shell {
  case effect {
    engine.ScheduleFlush(after_ms:) -> {
      process.send_after(shell.subject, after_ms, engine.FlushLogs)
      shell
    }
    engine.Post(request) -> {
      let inbox = shell.subject
      let send = shell.send
      let pid =
        process.spawn_unlinked(fn() {
          process.send(inbox, engine.Posted(send(request)))
        })
      Shell(..shell, poster: Some(#(pid, process.monitor(pid))))
    }
  }
}

/// Sends to the subject, swallowing the panic `process.send` raises while
/// a named subject's name is unregistered.
@external(erlang, "gloss_sentry_ffi", "try_send")
fn try_send(subject: Subject(Message), message: Message) -> Nil

@external(erlang, "crypto", "strong_rand_bytes")
fn random_bytes(n: Int) -> BitArray

/// A uuid4 as 32 lowercase hex characters.
fn event_id() -> String {
  let assert <<
    a:bits-size(48),
    _:size(4),
    b:bits-size(12),
    _:size(2),
    c:bits-size(62),
  >> = random_bytes(16)
  <<a:bits, 4:size(4), b:bits, 2:size(2), c:bits>>
  |> bit_array.base16_encode
  |> string.lowercase
}

fn node_name() -> String {
  node.self() |> node.name |> atom.to_string
}

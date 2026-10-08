//// Export gloss tracer spans and logs to OpenTelemetry over OTLP/HTTP
//// (JSON), to a collector or any service that accepts OTLP.
////
//// ```gleam
//// let assert Ok(otel) =
////   gloss_otel.config("http://localhost:4318")
////   |> gloss_otel.service_name("forum")
////   |> gloss_otel.service_version("1.4.0")
////   |> gloss_otel.start(httpc.send)
////
//// let tracer = tracer.new() |> tracer.handle(gloss_otel.handler(otel))
//// let log = logger.stack([logger.stderr(), gloss_otel.logger(otel)])
//// ```
////
//// Every `tracer.Span` becomes a span, sent to `/v1/traces`. Every
//// `tracer.Point` becomes a log record, sent to `/v1/logs` with the trace
//// and span it happened in. Entries written to `logger(otel)` become log
//// records too, tied to their request's trace by the `request_id` gloss/http
//// puts on each handler's logger. A tracer that already forwards points to
//// that logger (`logger.trace_handler`) would send them twice, so use one
//// or the other for points.
////
//// gloss's HTTP and SQL spans are sent with the OpenTelemetry semantic
//// convention names (`http.route`, `http.response.status_code`,
//// `db.query.text`, ...), and as `SERVER` and `CLIENT` spans, so tracing
//// tools recognise them.
////
//// ## Sending
////
//// `start` and `supervised` take the function that performs the HTTP POST,
//// typically `httpc.send`, so this package has no HTTP client dependency and
//// tests can record requests instead. Spans and records are sent in batches
//// of up to 512, at most five seconds after the first one arrives. One
//// request is in flight at a time; the rest wait in a queue of 8 that drops
//// its oldest request when full. A `429`, `502`, `503`, `504` or transport
//// error pauses sending, for as long as `Retry-After` asks or else for 1, 2,
//// 4 ... up to 30 seconds, then the request is tried again. Other failures
//// drop the request. Memory stays bounded whatever the collector does.
////
//// Call `flush` before the node stops so the last batch isn't lost.

import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{type Name, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import gloss/internal/poster.{type Poster}
import gloss/internal/runtime
import gloss/logger.{type Logger}
import gloss/meta.{type Meta}
import gloss/tracer
import gloss_otel/internal/engine

/// Messages the exporter process understands. Opaque to applications; it
/// is exposed so a `process.Name(Message)` can be created for `named`.
pub opaque type Message {
  Engine(engine.Message)
  Flush(reply: Subject(Nil))
}

/// Where and how to export. Build one with `config` and the setters.
pub opaque type Config {
  Config(
    endpoint: String,
    service_name: String,
    service_version: Option(String),
    resource: Meta,
    headers: List(#(String, String)),
    max_batch: Int,
    max_queue: Int,
    interval: Duration,
    name: Option(Name(Message)),
  )
}

/// Export to an OTLP/HTTP endpoint such as `http://localhost:4318`, where
/// `/v1/traces` and `/v1/logs` are appended. Defaults: service
/// `unknown_service:beam`, batches of 512, a queue of 8 requests, and a
/// five-second interval.
pub fn config(endpoint: String) -> Config {
  Config(
    endpoint:,
    service_name: "unknown_service:beam",
    service_version: None,
    resource: [],
    headers: [],
    max_batch: 512,
    max_queue: 8,
    interval: duration.seconds(5),
    name: None,
  )
}

/// The `service.name` resource attribute, which tools group by.
pub fn service_name(config: Config, name: String) -> Config {
  Config(..config, service_name: name)
}

pub fn service_version(config: Config, version: String) -> Config {
  Config(..config, service_version: Some(version))
}

/// More resource attributes, e.g.
/// `[#("deployment.environment.name", meta.String("production"))]`.
pub fn resource(config: Config, attributes: Meta) -> Config {
  Config(..config, resource: list.append(config.resource, attributes))
}

/// A header on every request, such as a vendor's API key.
pub fn header(config: Config, name: String, value: String) -> Config {
  Config(
    ..config,
    headers: list.append(config.headers, [#(string.lowercase(name), value)]),
  )
}

/// Spans or log records per request.
pub fn max_batch(config: Config, max_batch: Int) -> Config {
  Config(..config, max_batch:)
}

/// How many requests may wait to be sent before the oldest is dropped.
pub fn max_queue(config: Config, max_queue: Int) -> Config {
  Config(..config, max_queue:)
}

/// The longest a span or record waits for its batch to fill.
pub fn interval(config: Config, interval: Duration) -> Config {
  Config(..config, interval:)
}

/// Register the exporter under `name`, so `from_name` reaches it across
/// restarts.
pub fn named(config: Config, name: Name(Message)) -> Config {
  Config(..config, name: Some(name))
}

/// A handle on an exporter. Every operation is one message send.
pub opaque type Otel {
  Otel(subject: Subject(Message))
}

pub type StartError {
  InvalidEndpoint(String)
  /// The exporter process could not start.
  Unavailable(reason: String)
}

/// The function that performs the HTTP POST, e.g. `httpc.send`. It runs in
/// a helper process, never in the caller's.
pub type Send(error) =
  fn(Request(String)) -> Result(Response(String), error)

/// Start an exporter outside a supervision tree.
pub fn start(config: Config, send: Send(e)) -> Result(Otel, StartError) {
  use settings <- result.try(settings(config))
  case start_actor(config, settings, send) {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(Unavailable(string.inspect(error)))
  }
}

/// A child for a supervision tree. An invalid endpoint fails the start.
pub fn supervised(config: Config, send: Send(e)) -> ChildSpecification(Otel) {
  supervision.worker(fn() {
    case settings(config) {
      Ok(settings) -> start_actor(config, settings, send)
      Error(_) ->
        Error(actor.InitFailed("invalid endpoint: " <> config.endpoint))
    }
  })
}

/// A handle for an exporter configured with `named`. Usable before the
/// exporter starts; events are dropped while it is not running.
pub fn from_name(name: Name(Message)) -> Otel {
  Otel(process.named_subject(name))
}

/// A tracer handler that exports every span and point.
pub fn handler(otel: Otel) -> tracer.Handler {
  fn(event) { try_send(otel.subject, Engine(engine.Traced(event))) }
}

/// A log channel that exports entries as log records.
pub fn logger(otel: Otel) -> Logger {
  logger.new(fn(entry) { try_send(otel.subject, Engine(engine.Logged(entry))) })
}

/// Send everything buffered now, and wait up to `timeout` for it to be
/// accepted. `Error(Nil)` when it wasn't all sent in time, such as while
/// the collector is unreachable.
pub fn flush(otel: Otel, timeout: Duration) -> Result(Nil, Nil) {
  let reply = process.new_subject()
  try_send(otel.subject, Flush(reply))
  process.receive(reply, duration.to_milliseconds(timeout))
}

/// Stop the exporter. Buffered and queued data is dropped; `flush` first
/// to keep it.
pub fn stop(otel: Otel) -> Nil {
  try_send(otel.subject, Engine(engine.Stop))
}

fn settings(config: Config) -> Result(engine.Settings, StartError) {
  let request = fn(path) {
    engine.signal_request(config.endpoint, path, config.headers)
    |> result.replace_error(InvalidEndpoint(config.endpoint))
  }
  use traces <- result.try(request(["v1", "traces"]))
  use logs <- result.map(request(["v1", "logs"]))
  engine.Settings(
    traces:,
    logs:,
    resource: resource_attributes(config),
    max_batch: int_max(config.max_batch, 1),
    max_queue: int_max(config.max_queue, 1),
    interval_ms: duration.to_milliseconds(config.interval),
  )
}

fn resource_attributes(config: Config) -> Meta {
  list.flatten([
    [#("service.name", meta.String(config.service_name))],
    case config.service_version {
      Some(version) -> [#("service.version", meta.String(version))]
      None -> []
    },
    [
      #("service.instance.id", meta.String(node_name())),
      #("telemetry.sdk.name", meta.String("gloss_otel")),
      #("telemetry.sdk.language", meta.String("erlang")),
      #("telemetry.sdk.version", meta.String("0.1.0")),
    ],
    config.resource,
  ])
}

type Shell {
  Shell(
    subject: Subject(Message),
    send: fn(Request(String)) -> Result(Response(String), String),
    /// The request in flight, if any.
    poster: Poster,
    /// Callers of `flush` waiting for everything to be sent.
    waiting: List(Subject(Nil)),
    state: engine.State,
  )
}

fn start_actor(
  config: Config,
  settings: engine.Settings,
  send: Send(e),
) -> Result(actor.Started(Otel), actor.StartError) {
  let send = fn(request) { send(request) |> result.map_error(string.inspect) }
  let builder =
    actor.new_with_initialiser(1000, fn(subject) {
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(fn(down) { Engine(engine.Down(down)) })
      Shell(
        subject:,
        send:,
        poster: poster.new(),
        waiting: [],
        state: engine.init(settings),
      )
      |> actor.initialised
      |> actor.selecting(selector)
      |> actor.returning(Otel(subject))
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
    Engine(engine.Stop) -> actor.stop()
    Flush(reply:) ->
      step(Shell(..shell, waiting: [reply, ..shell.waiting]), engine.Tick)
    Engine(engine.Down(down) as message) ->
      case poster.down(shell.poster, down) {
        #(poster, True) -> step(Shell(..shell, poster:), message)
        #(_, False) -> actor.continue(shell)
      }
    Engine(engine.Posted(_) as posted) ->
      step(Shell(..shell, poster: poster.settled(shell.poster)), posted)
    Engine(message) -> step(shell, message)
  }
}

fn step(shell: Shell, message: engine.Message) -> actor.Next(Shell, Message) {
  let #(state, effects) =
    engine.handle(shell.state, message, timestamp.system_time())
  let shell = list.fold(effects, Shell(..shell, state:), perform)
  case engine.idle(shell.state) {
    True -> {
      list.each(shell.waiting, process.send(_, Nil))
      actor.continue(Shell(..shell, waiting: []))
    }
    False -> actor.continue(shell)
  }
}

fn perform(shell: Shell, effect: engine.Effect) -> Shell {
  case effect {
    engine.Schedule(after_ms:, message:) -> {
      process.send_after(shell.subject, after_ms, Engine(message))
      shell
    }
    engine.Post(request) ->
      Shell(
        ..shell,
        poster: poster.post(
          shell.poster,
          shell.subject,
          shell.send,
          request,
          fn(result) { Engine(engine.Posted(result)) },
        ),
      )
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

fn node_name() -> String {
  node.self() |> node.name |> atom.to_string
}

/// Send, dropping the message if the receiver is gone.
fn try_send(subject: Subject(message), message: message) -> Nil {
  let _ = runtime.try_send(subject, message)
  Nil
}

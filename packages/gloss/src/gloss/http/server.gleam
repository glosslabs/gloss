//// An HTTP/1.1 server for a `Router`.
////
//// ```gleam
//// let assert Ok(srv) =
////   server.new(routes.routes(), ctx)
////   |> server.port(4000)
////   |> server.tracer(ctx.tracer)
////   |> server.logger(ctx.log)
////   |> server.with(cors)
////   |> server.start
////
//// signal.wait_for_terminate()
//// let _ = server.shutdown(srv)
//// ```
////
//// ## Every request
////
//// For each request the server:
////
//// 1. takes the request id from `x-request-id`, or generates one, and
////    returns it in the response's `x-request-id`;
//// 2. matches a route and builds the handler's `Context`, whose logger
////    carries `request_id` and `route`;
//// 3. runs the server middleware, the route's middleware and the handler,
////    answering `500` if any of them panics;
//// 4. emits one `tracer.Span` with source `"gloss.http"`, named after the
////    method and route (`"GET /notes/:id"`, or just `"GET"` when no route
////    matched), with `method`, `path`, `route`, `status`, `request_id` and
////    `bytes` in its meta. The span has an `error` when the handler panicked
////    or the status is 5xx.
////
//// Attach `logger.trace_handler` to the tracer for an access log, and
//// `gloss_sentry.handler` to report failed requests to Sentry.
////
//// Requests rejected before routing (malformed, too large, too slow) are
//// answered directly and reported as `Warning` points named
//// `"request.rejected"`.
////
//// Error replies (`reply.error` and friends, and the server's own 404,
//// 405, 413, 500, ...) are rendered in the format the request's `Accept`
//// header prefers: JSON, problem+json, HTML (see `error_page`) or plain
//// text, defaulting to JSON. See `gloss/http/reply`.
////
//// ## Limits
////
//// Bodies must be sent with `Content-Length`; a chunked request body is
//// answered `501`. Responses are always sent with `Content-Length`. There
//// is no TLS: run behind a proxy that terminates it.

import gleam/bytes_tree.{type BytesTree}
import gleam/dict
import gleam/erlang/atom.{type Atom}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import gloss/http/context.{type Handler, type Middleware, Context}
import gloss/http/reply.{type ErrorPage, type Request}
import gloss/http/router.{type RouteError, type Router}
import gloss/internal/http_reply_render as reply_render
import gloss/internal/http_server_connection as connection
import gloss/internal/http_server_control as control
import gloss/logger.{type Logger}
import gloss/meta
import gloss/tracer.{type Tracer}

/// How to serve a router. Build one with `new` and the setters, then
/// `start` or `supervised` it.
pub opaque type Builder(state) {
  Builder(
    router: Router(state),
    state: state,
    interface: String,
    port: Int,
    tracer: Tracer,
    logger: Logger,
    middleware: List(Middleware(state)),
    max_body: Int,
    max_headers: Int,
    header_timeout: Duration,
    idle_timeout: Duration,
    shutdown_timeout: Duration,
    acceptors: Int,
    on_started: List(fn(Started) -> Nil),
    on_stopped: List(fn(Stopped) -> Nil),
    error_page: fn(ErrorPage) -> String,
  )
}

/// A running server.
pub opaque type Server {
  Server(
    handle: control.Handle,
    shutdown_timeout: Int,
    tracer: Tracer,
    on_stopped: List(fn(Stopped) -> Nil),
  )
}

pub type Started {
  Started(interface: String, port: Int)
}

pub type Stopped {
  /// `killed` connections were still open when the drain deadline passed.
  Stopped(killed: Int)
}

pub type StartError {
  /// Two routes share a method and path, or two share a name.
  InvalidRoutes(List(RouteError))
  AddressInUse(port: Int)
  InvalidInterface(interface: String)
  Unavailable(reason: String)
}

pub type ShutdownError {
  /// The drain deadline passed with `remaining` connections still open;
  /// they were killed.
  TimedOut(remaining: Int)
}

const source = "gloss.http"

/// Serve `router`, giving `state` to every handler as `ctx.state`.
///
/// Defaults: `127.0.0.1:4000`, no tracer handlers, logs discarded, 1 MiB
/// bodies, 100 headers, 10 second header timeout, 60 second keep-alive
/// idle timeout, 10 second shutdown timeout, 10 acceptors.
pub fn new(router: Router(state), state: state) -> Builder(state) {
  Builder(
    router:,
    state:,
    interface: "127.0.0.1",
    port: 4000,
    tracer: tracer.new(),
    logger: logger.discard(),
    middleware: [],
    max_body: 1_048_576,
    max_headers: 100,
    header_timeout: duration.seconds(10),
    idle_timeout: duration.seconds(60),
    shutdown_timeout: duration.seconds(10),
    acceptors: 10,
    on_started: [],
    on_stopped: [],
    error_page: reply.default_error_page,
  )
}

/// The port to listen on. `0` picks a free one; read it with `port_of`.
pub fn port(builder: Builder(state), port: Int) -> Builder(state) {
  Builder(..builder, port:)
}

/// The address to listen on, e.g. `"0.0.0.0"` for every IPv4 interface or
/// `"::"` for every IPv6 one.
pub fn bind(builder: Builder(state), interface: String) -> Builder(state) {
  Builder(..builder, interface:)
}

pub fn tracer(builder: Builder(state), tracer: Tracer) -> Builder(state) {
  Builder(..builder, tracer:)
}

/// The logger handlers receive as `ctx.log`, with `request_id` and `route`
/// added.
pub fn logger(builder: Builder(state), logger: Logger) -> Builder(state) {
  Builder(..builder, logger:)
}

/// Wrap every request, including ones that match no route, with
/// `middleware`. It runs after routing, so `ctx.route` and `ctx.params` are
/// set, and outside the route's own middleware. Middleware attached first
/// runs outermost.
pub fn with(
  builder: Builder(state),
  middleware: Middleware(state),
) -> Builder(state) {
  Builder(..builder, middleware: list.append(builder.middleware, [middleware]))
}

/// The largest request body accepted, in bytes. Larger ones are answered
/// `413`.
pub fn max_body(builder: Builder(state), bytes: Int) -> Builder(state) {
  Builder(..builder, max_body: bytes)
}

/// The most headers a request may have. More are answered `431`.
pub fn max_headers(builder: Builder(state), count: Int) -> Builder(state) {
  Builder(..builder, max_headers: count)
}

/// How long a client may take over each header line and over the body.
pub fn header_timeout(
  builder: Builder(state),
  timeout: Duration,
) -> Builder(state) {
  Builder(..builder, header_timeout: timeout)
}

/// How long a kept-alive connection may wait for its next request.
pub fn idle_timeout(
  builder: Builder(state),
  timeout: Duration,
) -> Builder(state) {
  Builder(..builder, idle_timeout: timeout)
}

/// How long `shutdown` waits for in-flight requests before closing their
/// connections.
pub fn shutdown_timeout(
  builder: Builder(state),
  timeout: Duration,
) -> Builder(state) {
  Builder(..builder, shutdown_timeout: timeout)
}

/// How many processes accept connections concurrently.
pub fn acceptors(builder: Builder(state), count: Int) -> Builder(state) {
  Builder(..builder, acceptors: count)
}

/// Called once the server is listening.
pub fn on_started(
  builder: Builder(state),
  f: fn(Started) -> Nil,
) -> Builder(state) {
  Builder(..builder, on_started: list.append(builder.on_started, [f]))
}

/// Called when `shutdown` finishes.
pub fn on_stopped(
  builder: Builder(state),
  f: fn(Stopped) -> Nil,
) -> Builder(state) {
  Builder(..builder, on_stopped: list.append(builder.on_stopped, [f]))
}

/// Render error replies for clients that prefer HTML. The page is given
/// the status, its reason phrase, the message and any details, and must
/// escape them (see `reply.escape`). Defaults to `reply.default_error_page`.
pub fn error_page(
  builder: Builder(state),
  render: fn(ErrorPage) -> String,
) -> Builder(state) {
  Builder(..builder, error_page: render)
}

// --- Lifecycle ---------------------------------------------------------------

/// Start listening, outside a supervision tree. The server is linked to the
/// calling process.
pub fn start(builder: Builder(state)) -> Result(Server, StartError) {
  use table <- result.try(
    router.table(builder.router) |> result.map_error(InvalidRoutes),
  )
  case start_control(builder, table) {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(start_error(builder, error))
  }
}

/// A child for a supervision tree. Stopping the tree drains the server like
/// `shutdown`; the child's shutdown timeout allows for it. A server stopped
/// with `shutdown` is not restarted.
pub fn supervised(builder: Builder(state)) -> ChildSpecification(Server) {
  supervision.worker(fn() {
    case router.table(builder.router) {
      Ok(table) -> start_control(builder, table)
      Error(errors) ->
        Error(actor.InitFailed("invalid routes: " <> string.inspect(errors)))
    }
  })
  |> supervision.timeout(ms(builder.shutdown_timeout) + 1000)
  |> supervision.restart(supervision.Transient)
}

/// The port the server is listening on.
pub fn port_of(server: Server) -> Int {
  server.handle.port
}

/// Stop accepting connections, let in-flight requests finish, then stop.
/// Idle keep-alive connections are closed at once. Connections still busy
/// when the shutdown timeout passes are closed and counted in `TimedOut`.
pub fn shutdown(server: Server) -> Result(Nil, ShutdownError) {
  let result = control.shutdown(server.handle, server.shutdown_timeout)
  let killed = case result {
    Ok(Nil) -> 0
    Error(n) -> n
  }
  list.each(server.on_stopped, fn(f) { f(Stopped(killed:)) })
  tracer.point(
    server.tracer,
    source:,
    name: "server.stopped",
    level: case killed {
      0 -> tracer.Info
      _ -> tracer.Warning
    },
    meta: fn() { [#("killed", meta.Int(killed))] },
  )
  result.map_error(result, TimedOut)
}

fn start_control(
  builder: Builder(state),
  table: router.Table(state),
) -> Result(actor.Started(Server), actor.StartError) {
  let pipeline = pipeline(builder, table)
  let settings =
    connection.Settings(
      handler: pipeline,
      render: fn(response, accept) {
        reply_render.render(response, accept, builder.error_page)
      },
      max_body: builder.max_body,
      header_timeout: ms(builder.header_timeout),
      idle_timeout: ms(builder.idle_timeout),
      max_headers: builder.max_headers,
      report: report_problem(builder.tracer, _),
    )
  let config =
    control.Config(
      interface: builder.interface,
      port: builder.port,
      acceptors: builder.acceptors,
      shutdown_timeout: ms(builder.shutdown_timeout),
      serve: connection.serve(_, settings),
      on_accept_error: fn(reason) {
        tracer.point(
          builder.tracer,
          source:,
          name: "accept.failed",
          level: tracer.Error,
          meta: fn() { [#("reason", meta.String(reason))] },
        )
      },
    )
  use started <- result.map(control.start(config))
  let port = started.data.port
  let info = Started(interface: builder.interface, port:)
  list.each(builder.on_started, fn(f) { f(info) })
  tracer.point(
    builder.tracer,
    source:,
    name: "server.started",
    level: tracer.Info,
    meta: fn() {
      [
        #("interface", meta.String(builder.interface)),
        #("port", meta.Int(port)),
      ]
    },
  )
  actor.Started(
    pid: started.pid,
    data: Server(
      handle: started.data,
      shutdown_timeout: ms(builder.shutdown_timeout),
      tracer: builder.tracer,
      on_stopped: builder.on_stopped,
    ),
  )
}

fn start_error(builder: Builder(state), error: actor.StartError) -> StartError {
  case control.start_error(error) {
    control.AddressInUse -> AddressInUse(builder.port)
    control.InvalidInterface -> InvalidInterface(builder.interface)
    control.ListenFailed(reason) -> Unavailable(reason)
  }
}

fn report_problem(tracer: Tracer, problem: connection.Problem) -> Nil {
  use <- tracer.point(
    tracer,
    source:,
    name: "request.rejected",
    level: tracer.Warning,
  )
  let reason = [#("reason", meta.String(connection.message(problem)))]
  case problem {
    connection.Malformed(detail:) -> [
      #("detail", meta.String(detail)),
      ..reason
    ]
    connection.BodyTooLarge(length:) -> [
      #("length", meta.Int(length)),
      ..reason
    ]
    _ -> reason
  }
}

// --- The request pipeline ----------------------------------------------------

/// Run one request through routing, middleware and the handler, as the
/// server would, without a socket. For tests:
///
/// ```gleam
/// let res = server.handle(web.builder(ctx), request)
/// res.status |> should.equal(200)
/// ```
///
/// Panics when the router has duplicate routes or names.
pub fn handle(
  builder: Builder(state),
  request: Request,
) -> Response(BytesTree) {
  case router.table(builder.router) {
    Ok(table) -> pipeline(builder, table)(request)
    Error(errors) -> panic as { "invalid routes: " <> string.inspect(errors) }
  }
}

fn pipeline(
  builder: Builder(state),
  table: router.Table(state),
) -> fn(Request) -> Response(BytesTree) {
  let Builder(state:, logger: log, tracer: trace, middleware:, error_page:, ..) =
    builder
  fn(request: Request) {
    let at = timestamp.system_time()
    let started = monotonic_ns()
    let request_id = request_id(request)

    let #(route, params, handler) = case
      router.match(table, request.method, request.path)
    {
      router.Matched(route:, params:, handler:) -> #(route, params, handler)
      router.MethodNotAllowed(handler:, ..) -> #("", dict.new(), handler)
      router.NotFound(handler:) -> #("", dict.new(), handler)
    }
    let ctx =
      Context(
        state:,
        params:,
        route:,
        request_id:,
        log: logger.with_context(log, log_context(request_id, route)),
        tracer: trace,
      )
    let handler = wrap(handler, middleware)

    let #(response, failure) = case rescue(fn() { handler(request, ctx) }) {
      Ok(response) if response.status >= 500 -> #(
        response,
        Some("HTTP " <> int.to_string(response.status)),
      )
      Ok(response) -> #(response, None)
      Error(panic_) -> #(reply.internal_error(), Some(panic_))
    }
    let response =
      response
      |> response.set_header("x-request-id", request_id)
      |> reply_render.render(request.get_header(request, "accept"), error_page)

    tracer.emit(trace, fn() {
      tracer.Span(
        source:,
        name: span_name(request.method, route),
        at:,
        meta: span_meta(request, route, response, request_id),
        duration: duration.nanoseconds(monotonic_ns() - started),
        error: failure,
      )
    })
    response
  }
}

fn wrap(
  handler: Handler(state),
  middleware: List(Middleware(state)),
) -> Handler(state) {
  list.fold_right(middleware, handler, fn(handler, middleware) {
    middleware(handler)
  })
}

fn request_id(request: Request) -> String {
  case request.get_header(request, "x-request-id") {
    Ok(id) ->
      case string.length(id) {
        n if n > 0 && n <= 128 -> id
        _ -> random_id()
      }
    Error(Nil) -> random_id()
  }
}

fn log_context(request_id: String, route: String) -> meta.Meta {
  case route {
    "" -> [#("request_id", meta.String(request_id))]
    _ -> [
      #("request_id", meta.String(request_id)),
      #("route", meta.String(route)),
    ]
  }
}

fn span_name(method: http.Method, route: String) -> String {
  case route {
    "" -> http.method_to_string(method)
    _ -> http.method_to_string(method) <> " " <> route
  }
}

fn span_meta(
  request: Request,
  route: String,
  response: Response(BytesTree),
  request_id: String,
) -> meta.Meta {
  [
    #("method", meta.String(http.method_to_string(request.method))),
    #("path", meta.String(request.path)),
    #("route", meta.String(route)),
    #("status", meta.Int(response.status)),
    #("request_id", meta.String(request_id)),
    #("bytes", meta.Int(bytes_tree.byte_size(response.body))),
  ]
}

fn ms(duration: Duration) -> Int {
  duration.to_milliseconds(duration)
}

fn monotonic_ns() -> Int {
  monotonic_time(atom.create("nanosecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

@external(erlang, "gloss@http@server_ffi", "rescue")
fn rescue(work: fn() -> a) -> Result(a, String)

@external(erlang, "gloss@http@server_ffi", "random_id")
fn random_id() -> String

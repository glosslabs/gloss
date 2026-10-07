//// The HTTP server: the routes, served with the application's logger and
//// tracer, CSRF protection and compression.

import app/config.{type Config}
import gloss/http/compress
import gloss/http/csrf
import gloss/http/server.{
  type Builder, type Server, type ShutdownError, type StartError,
}
import gloss/http/session.{type Sessions}
import gloss/http/static
import gloss/logger.{type Logger}
import gloss/tracer.{type Tracer}
import server/routes
import server/state.{type State}
import server/views/errors

/// The server for the application's state, with the infrastructure the
/// server owns: its logger, tracer and sessions.
pub fn builder(
  config: Config,
  state: State,
  log log: Logger,
  tracer tracer: Tracer,
  sessions sessions: Sessions,
) -> Builder(State) {
  let assets_dir = case static.priv("app") {
    Ok(priv) -> priv <> "/static"
    Error(Nil) -> "priv/static"
  }
  routes.routes(assets_dir:, avatars_dir: state.avatars_dir)
  |> server.new(state)
  |> server.bind("0.0.0.0")
  |> server.port(config.port)
  |> server.tracer(tracer)
  |> server.logger(log)
  |> server.sessions(sessions)
  |> server.with(csrf.protect)
  |> server.with(compress.gzip)
  |> server.error_page(errors.page)
}

pub fn start(
  config: Config,
  state: State,
  log log: Logger,
  tracer tracer: Tracer,
  sessions sessions: Sessions,
) -> Result(Server, StartError) {
  builder(config, state, log:, tracer:, sessions:) |> server.start
}

/// Finish in-flight requests, then stop.
pub fn stop(server: Server) -> Result(Nil, ShutdownError) {
  server.shutdown(server)
}

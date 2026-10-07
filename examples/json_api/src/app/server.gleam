//// The HTTP server: every route group, served with the application's
//// logger and tracer.

import app/config.{type Config}
import app/routes/api
import app/state.{type State}
import gloss/http/router
import gloss/http/server.{
  type Builder, type Server, type ShutdownError, type StartError,
}
import gloss/logger.{type Logger}
import gloss/tracer.{type Tracer}

/// The server for the application's state, with the logger and tracer the
/// server owns.
pub fn builder(
  config: Config,
  state: State,
  log log: Logger,
  tracer tracer: Tracer,
) -> Builder(State) {
  router.combine([api.routes()])
  |> server.new(state)
  |> server.bind("0.0.0.0")
  |> server.port(config.port)
  |> server.tracer(tracer)
  |> server.logger(log)
}

pub fn start(
  config: Config,
  state: State,
  log log: Logger,
  tracer tracer: Tracer,
) -> Result(Server, StartError) {
  builder(config, state, log:, tracer:) |> server.start
}

/// Finish in-flight requests, then stop.
pub fn stop(server: Server) -> Result(Nil, ShutdownError) {
  server.shutdown(server)
}

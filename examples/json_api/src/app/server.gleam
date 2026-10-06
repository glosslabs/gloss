//// The HTTP server: every route group, served with the application's
//// logger and tracer.

import app/config.{type Config}
import app/routes/api
import app/state.{type State}
import gloss/http/router
import gloss/http/server.{
  type Builder, type Server, type ShutdownError, type StartError,
}

pub fn builder(config: Config, state: State) -> Builder(State) {
  router.combine([api.routes()])
  |> server.new(state)
  |> server.bind("0.0.0.0")
  |> server.port(config.port)
  |> server.tracer(state.tracer)
  |> server.logger(state.log)
}

pub fn start(config: Config, state: State) -> Result(Server, StartError) {
  builder(config, state) |> server.start
}

/// Finish in-flight requests, then stop.
pub fn stop(server: Server) -> Result(Nil, ShutdownError) {
  server.shutdown(server)
}

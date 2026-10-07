import app/config.{type Config}
import gloss/http/compress
import gloss/http/cookie
import gloss/http/csrf
import gloss/http/secure_headers
import gloss/http/server.{
  type Builder, type Server, type ShutdownError, type StartError,
}
import gloss/http/session
import gloss/http/session/file
import gloss/http/static
import gloss/logger.{type Logger}
import gloss/tracer.{type Tracer}
import server/routing
import server/state.{type State}
import server/views/errors

pub fn builder(
  config config: Config,
  state state: State,
  logger logger: Logger,
  tracer tracer: Tracer,
) -> Builder(State) {
  let assets_dir = case static.priv("app") {
    Ok(priv) -> priv <> "/static"
    Error(Nil) -> "priv/static"
  }

  // Kept on disk, so logins survive a restart.
  let assert Ok(store) = file.start(config.data_dir <> "/sessions.dets")
  let sessions =
    session.new(store)
    |> session.cookie_name("forum_session")
    |> session.cookie_attributes(
      cookie.defaults()
      |> cookie.secure(config.environment != "development"),
    )

  routing.routes(assets_dir:, avatars_dir: state.avatars_dir)
  |> server.new(state)
  |> server.bind("0.0.0.0")
  |> server.port(config.port)
  |> server.tracer(tracer)
  |> server.logger(logger)
  |> server.sessions(sessions)
  |> server.with(secure_headers.protect)
  |> server.with(csrf.protect)
  |> server.with(compress.gzip)
  |> server.error_page(errors.page)
}

pub fn start_with(
  config config: Config,
  state state: State,
  logger logger: Logger,
  tracer tracer: Tracer,
) -> Result(Server, StartError) {
  server.start(builder(config:, state:, logger:, tracer:))
}

/// Finish in-flight requests, then stop.
pub fn stop(server: Server) -> Result(Nil, ShutdownError) {
  server.shutdown(server)
}

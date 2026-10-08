import app/config
import app/logging
import app/notes
import app/sentry
import app/server
import app/state
import app/tracing
import gloss/http/server as http_server
import gloss/logger
import gloss/meta
import gloss/signal
import gloss/sqlite
import gloss/tracer

pub fn main() -> Nil {
  let config = config.from_env()

  let sentry = sentry.start(config)
  let log =
    logger.stack([
      logging.console(),
      logging.files(config),
      logging.to_sentry(sentry),
    ])
  let tracer =
    tracer.new()
    |> tracing.with_logger(log)
    |> tracing.with_sentry(sentry)

  let assert Ok(notes) = notes.start(sqlite.file(config.database_path))
  let state = state.new(config, notes:)

  let assert Ok(srv) = server.start(config, state, log:, tracer:)
  signal.wait_for_terminate()
  case server.stop(srv) {
    Ok(Nil) -> Nil
    Error(http_server.TimedOut(remaining:)) ->
      log.error("shutdown timed out; open connections were closed", [
        #("remaining", meta.Int(remaining)),
      ])
  }
}

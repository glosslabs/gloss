import app/config
import app/logging
import app/tracing
import domain/accounts
import domain/forum
import gloss/http/server as http_server
import gloss/meta
import gloss/signal
import gloss/tracer
import infra/sentry
import server
import server/state

pub fn main() -> Nil {
  let config = config.from_env()
  let log = logging.default(config)
  let sentry = sentry.start(config.sentry_dsn, config.environment)

  let tracer =
    tracer.new()
    |> tracing.with_logger(log)
    |> tracing.with_sentry(sentry)

  let assert Ok(accounts) = accounts.start()
  let assert Ok(forum) = forum.start()

  let state =
    state.new(accounts:, forum:, avatars_dir: config.data_dir <> "/avatars")

  let assert Ok(srv) = server.start_with(config:, state:, logger: log, tracer:)

  signal.wait_for_terminate()

  case server.stop(srv) {
    Ok(Nil) -> Nil
    Error(http_server.TimedOut(remaining:)) -> {
      log.error("shutdown timed out; open connections were closed", [
        #("remaining", meta.Int(remaining)),
      ])
    }
  }
}

import app/config
import app/db
import app/debug
import app/logging
import app/otel
import app/sentry
import app/tracing
import domain/accounts
import domain/forum
import gleam/option.{None, Some}
import gleam/time/duration
import gloss/clock
import gloss/http/server as http_server
import gloss/meta
import gloss/signal
import gloss/tracer
import gloss_otel
import server
import server/state
import store/threads
import store/users

pub fn main() -> Nil {
  let config = config.from_env()
  let log = logging.default(config)
  let sentry = sentry.start(config)
  let otel = otel.start(config)
  let bar = debug.start(config)

  let tracer =
    tracer.new()
    |> tracing.with_logger(log)
    |> tracing.with_sentry(sentry)
    |> tracing.with_otel(otel)
    |> tracing.with_debug_bar(bar)

  let assert Ok(db) = db.start(config.database_url, tracer)
  let users = users.new(db)
  let threads = threads.new(db)

  let state =
    state.new(
      accounts: accounts.new(users, clock.system()),
      forum: forum.new(threads, clock.system()),
      avatars_dir: config.data_dir <> "/avatars",
    )

  let reloader = debug.reloader(config, tracer)
  let logger = tracing.handler_logger(log, otel:, debug_bar: bar)
  let assert Ok(srv) =
    server.builder(config:, state:, logger:, tracer:)
    |> debug.with_pages(bar, reloader)
    |> http_server.start

  signal.wait_for_terminate()

  case server.stop(srv) {
    Ok(Nil) -> Nil
    Error(http_server.TimedOut(remaining:)) -> {
      log.error("shutdown timed out; open connections were closed", [
        #("remaining", meta.Int(remaining)),
      ])
    }
  }
  // Send the last traces and logs before the node stops.
  case otel {
    Some(otel) -> {
      let _ = gloss_otel.flush(otel, duration.seconds(5))
      Nil
    }
    None -> Nil
  }
}

import app/config
import app/reporters
import domain/accounts
import domain/forum
import gloss/http/cookie
import gloss/http/session
import gloss/http/session/memory
import gloss/signal
import server
import server/state

pub fn main() -> Nil {
  let config = config.from_env()
  let #(log, tracer) = reporters.setup()

  let assert Ok(accounts) = accounts.start()
  let assert Ok(forum) = forum.start()

  let assert Ok(store) = memory.start()
  let sessions =
    session.new(store)
    |> session.cookie_name("forum_session")
    |> session.cookie_attributes(
      cookie.defaults()
      |> cookie.secure(config.environment != "development"),
    )
  let state =
    state.new(
      accounts:,
      forum:,
      sessions:,
      avatars_dir: config.data_dir <> "/avatars",
      log:,
    )

  let assert Ok(srv) = server.start(config, state, tracer)
  signal.wait_for_terminate()
  let _ = server.stop(srv)
  Nil
}

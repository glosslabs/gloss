import app/config
import app/notes
import app/reporters
import app/server
import app/state
import gloss/signal

pub fn main() -> Nil {
  let config = config.from_env()

  let #(log, tracer) = reporters.setup(config)
  let assert Ok(notes) = notes.start()
  let state = state.new(config, notes:)

  let assert Ok(srv) = server.start(config, state, log:, tracer:)
  signal.wait_for_terminate()
  let _ = server.stop(srv)
  Nil
}

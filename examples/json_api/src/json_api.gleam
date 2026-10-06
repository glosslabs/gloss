import gloss/http/server
import gloss/signal
import json_api/app
import json_api/config
import json_api/notes
import json_api/observability
import json_api/web

pub fn main() -> Nil {
  let config = config.from_env()
  let #(log, tracer) = observability.setup(config)
  let assert Ok(notes) = notes.start()
  let ctx = app.new(config, log:, tracer:, notes:)

  let assert Ok(srv) = web.start(config, ctx)
  signal.wait_for_terminate()
  let _ = server.shutdown(srv)
  Nil
}

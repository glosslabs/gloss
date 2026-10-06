import app/config.{type Config}
import app/notes.{type Notes}
import gleam/option.{type Option, None}
import gloss/logger.{type Logger}
import gloss/tracer.{type Tracer}

/// What every handler can reach through `ctx.state`.
pub type State {
  State(
    log: Logger,
    tracer: Tracer,
    notes: Notes,
    api_token: String,
    /// Set by `auth.authenticate` on routes that require it.
    user: Option(User),
  )
}

pub type User {
  User(name: String)
}

pub fn new(
  config: Config,
  log log: Logger,
  tracer tracer: Tracer,
  notes notes: Notes,
) -> State {
  State(log:, tracer:, notes:, api_token: config.api_token, user: None)
}

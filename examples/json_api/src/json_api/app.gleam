import gleam/option.{type Option, None}
import gloss/logger.{type Logger}
import gloss/tracer.{type Tracer}
import json_api/config.{type Config}
import json_api/notes.{type Notes}

/// What every handler can reach through `ctx.app`.
pub type App {
  App(
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
) -> App {
  App(log:, tracer:, notes:, api_token: config.api_token, user: None)
}

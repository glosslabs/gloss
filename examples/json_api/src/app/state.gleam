//// What every handler can reach through `ctx.state`: the application's
//// own services. The server's infrastructure (log, tracer) is on the
//// context itself.

import app/config.{type Config}
import app/notes.{type Notes}
import gleam/option.{type Option, None}

pub type State {
  State(
    notes: Notes,
    api_token: String,
    /// Set by `auth.authenticate` on routes that require it.
    user: Option(User),
  )
}

pub type User {
  User(name: String)
}

pub fn new(config: Config, notes notes: Notes) -> State {
  State(notes:, api_token: config.api_token, user: None)
}

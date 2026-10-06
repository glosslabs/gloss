//// What handlers reach through `ctx.state`.

import domain/accounts.{type Accounts}
import domain/accounts/user.{type User}
import domain/forum.{type Forum}
import gleam/option.{type Option, None}
import gloss/http/session.{type Sessions}
import gloss/logger.{type Logger}

pub type State {
  State(
    accounts: Accounts,
    forum: Forum,
    sessions: Sessions,
    /// Where avatar files are written and served from.
    avatars_dir: String,
    log: Logger,
    /// The signed-in user, set by `current_user.load`.
    user: Option(User),
  )
}

pub fn new(
  accounts accounts: Accounts,
  forum forum: Forum,
  sessions sessions: Sessions,
  avatars_dir avatars_dir: String,
  log log: Logger,
) -> State {
  State(accounts:, forum:, sessions:, avatars_dir:, log:, user: None)
}

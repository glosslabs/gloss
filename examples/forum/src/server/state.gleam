//// What handlers reach through `ctx.state`: the application's own
//// services. The server's infrastructure (log, tracer, sessions) is on the
//// context itself.

import domain/accounts.{type Accounts}
import domain/accounts/user.{type User}
import domain/forum.{type Forum}
import gleam/option.{type Option, None}

pub type State {
  State(
    accounts: Accounts,
    forum: Forum,
    /// Where avatar files are written and served from.
    avatars_dir: String,
    /// The signed-in user, set by `current_user.load`.
    user: Option(User),
  )
}

pub fn new(
  accounts accounts: Accounts,
  forum forum: Forum,
  avatars_dir avatars_dir: String,
) -> State {
  State(accounts:, forum:, avatars_dir:, user: None)
}

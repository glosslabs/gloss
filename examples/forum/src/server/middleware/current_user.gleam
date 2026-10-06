//// Who is signed in, from the session.

import domain/accounts
import domain/accounts/user.{type User}
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gloss/http/context.{type Context, type Handler, Context}
import gloss/http/reply.{type Request, type Response}
import gloss/http/session
import server/state.{type State, State}

/// Set `ctx.state.user` from the session, when someone is signed in.
pub fn load(next: Handler(State)) -> Handler(State) {
  fn(req: Request, ctx: Context(State)) {
    use s <- session.load(req, ctx.state.sessions)
    let user =
      session.get(s, "user_id")
      |> result.try(int.parse)
      |> result.try(accounts.get(ctx.state.accounts, _))
      |> option.from_result
    next(req, Context(..ctx, state: State(..ctx.state, user:)))
  }
}

/// Continue with the signed-in user, or send the visitor to sign in.
pub fn require(ctx: Context(State), next: fn(User) -> Response) -> Response {
  case ctx.state.user {
    Some(user) -> next(user)
    None -> reply.redirect("/login")
  }
}

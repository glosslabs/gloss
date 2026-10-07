import domain/accounts
import domain/accounts/user.{type User}
import gleam/int
import gleam/option.{None, Some}
import gloss/http/body
import gloss/http/context.{type Context}
import gloss/http/reply.{type Request, type Response}
import gloss/http/session
import server/handlers/forms
import server/state.{type State}
import server/views/accounts as views
import server/views/layout

pub fn register_form(_req: Request, ctx: Context(State)) -> Response {
  layout.page(200, "Register", ctx.state.user, views.register("", None))
}

pub fn register(req: Request, ctx: Context(State)) -> Response {
  use form <- body.form(req)
  let email = forms.value(form, "email")
  case
    accounts.register(ctx.state.accounts, email, forms.value(form, "password"))
  {
    Ok(user) -> sign_in(req, ctx, user)
    Error(error) ->
      layout.page(
        422,
        "Register",
        None,
        views.register(email, Some(views.register_error(error))),
      )
  }
}

pub fn login_form(_req: Request, ctx: Context(State)) -> Response {
  layout.page(200, "Sign in", ctx.state.user, views.login("", None))
}

pub fn login(req: Request, ctx: Context(State)) -> Response {
  use form <- body.form(req)
  let email = forms.value(form, "email")
  case
    accounts.authenticate(
      ctx.state.accounts,
      email,
      forms.value(form, "password"),
    )
  {
    Ok(user) -> sign_in(req, ctx, user)
    Error(Nil) ->
      layout.page(
        422,
        "Sign in",
        None,
        views.login(email, Some("The email or password is incorrect.")),
      )
  }
}

pub fn logout(req: Request, ctx: Context(State)) -> Response {
  use s <- session.load(req, ctx.sessions)
  session.destroy(s, reply.redirect("/"))
}

/// Start a session for the user, under a fresh id.
fn sign_in(req: Request, ctx: Context(State), user: User) -> Response {
  use s <- session.load(req, ctx.sessions)
  s
  |> session.regenerate
  |> session.set("user_id", int.to_string(user.id))
  |> session.save(reply.redirect("/"))
}

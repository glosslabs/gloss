import domain/accounts/user
import gleam/int
import gleam/option.{type Option}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import server/views/layout

pub fn register(email: String, error: Option(String)) -> List(Element(Nil)) {
  credentials_form("Register", "/register", email, error, "new-password")
}

pub fn login(email: String, error: Option(String)) -> List(Element(Nil)) {
  credentials_form("Sign in", "/login", email, error, "current-password")
}

fn credentials_form(
  title: String,
  action: String,
  email: String,
  error: Option(String),
  password_autocomplete: String,
) -> List(Element(Nil)) {
  [
    html.h1([], [html.text(title)]),
    layout.error(error),
    html.form([attribute.method("post"), attribute.action(action)], [
      layout.field(
        "Email",
        html.input([
          attribute.type_("email"),
          attribute.name("email"),
          attribute.value(email),
          attribute.autocomplete("email"),
          attribute.required(True),
        ]),
      ),
      layout.field(
        "Password",
        html.input([
          attribute.type_("password"),
          attribute.name("password"),
          attribute.autocomplete(password_autocomplete),
          attribute.required(True),
        ]),
      ),
      html.button([], [html.text(title)]),
    ]),
  ]
}

pub fn register_error(error: user.RegisterError) -> String {
  case error {
    user.InvalidEmail -> "Enter a valid email address."
    user.PasswordTooShort ->
      "Use at least " <> int.to_string(user.min_password) <> " characters."
    user.PasswordTooLong ->
      "Use at most " <> int.to_string(user.max_password) <> " characters."
    user.EmailTaken -> "That email is already registered."
  }
}

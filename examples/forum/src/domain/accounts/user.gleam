//// Users and the rules for their details. No IO.

import gleam/option.{type Option}
import gleam/string
import gleam/time/timestamp.{type Timestamp}

pub type User {
  User(
    id: Int,
    email: String,
    display_name: String,
    bio: String,
    /// The avatar's file name in the avatars directory.
    avatar: Option(String),
    password_hash: String,
    joined_at: Timestamp,
  )
}

pub type RegisterError {
  InvalidEmail
  PasswordTooShort
  PasswordTooLong
  EmailTaken
}

pub type ProfileError {
  DisplayNameMissing
  DisplayNameTooLong
  BioTooLong
}

pub const min_password = 8

pub const max_password = 128

pub const max_display_name = 40

pub const max_bio = 500

/// Trimmed and lowercased, with one `@` and something either side.
pub fn email(text: String) -> Result(String, RegisterError) {
  let email = string.lowercase(string.trim(text))
  case string.split(email, "@") {
    [local, domain] if local != "" && domain != "" && email != "" ->
      case string.contains(email, " ") || string.length(email) > 254 {
        True -> Error(InvalidEmail)
        False -> Ok(email)
      }
    _ -> Error(InvalidEmail)
  }
}

pub fn password(text: String) -> Result(String, RegisterError) {
  let length = string.length(text)
  case length < min_password, length > max_password {
    True, _ -> Error(PasswordTooShort)
    _, True -> Error(PasswordTooLong)
    False, False -> Ok(text)
  }
}

pub fn profile(
  display_name: String,
  bio: String,
) -> Result(#(String, String), ProfileError) {
  let display_name = string.trim(display_name)
  let bio = string.trim(bio)
  case display_name, string.length(display_name), string.length(bio) {
    "", _, _ -> Error(DisplayNameMissing)
    _, n, _ if n > max_display_name -> Error(DisplayNameTooLong)
    _, _, n if n > max_bio -> Error(BioTooLong)
    _, _, _ -> Ok(#(display_name, bio))
  }
}

/// The name a new user starts with: the part of their email before the `@`.
pub fn default_name(email: String) -> String {
  case string.split_once(email, "@") {
    Ok(#(local, _)) -> string.slice(local, 0, max_display_name)
    Error(Nil) -> email
  }
}

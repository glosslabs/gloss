import domain/accounts
import domain/accounts/user
import gleam/option.{None, Some}
import gleam/time/timestamp
import gleeunit/should
import gloss/clock
import gloss/testing/clock as test_clock
import support/memory_users

pub fn email_rules_test() {
  user.email("  Ada@Example.COM ") |> should.equal(Ok("ada@example.com"))
  user.email("no-at-sign") |> should.equal(Error(user.InvalidEmail))
  user.email("a@b@c") |> should.equal(Error(user.InvalidEmail))
  user.email("a b@c.d") |> should.equal(Error(user.InvalidEmail))
}

pub fn profile_rules_test() {
  user.profile("  Ada ", " hi ") |> should.equal(Ok(#("Ada", "hi")))
  user.profile(" ", "") |> should.equal(Error(user.DisplayNameMissing))
}

pub fn register_and_authenticate_test() {
  let joined = timestamp.from_unix_seconds(1_700_000_000)
  let time = test_clock.new(joined)
  let accounts = accounts.new(memory_users.start(), test_clock.clock(time))
  let assert Ok(ada) =
    accounts.register(accounts, "Ada@example.com", "correct horse")
  ada.display_name |> should.equal("ada")
  ada.joined_at |> should.equal(joined)
  accounts.register(accounts, "ada@EXAMPLE.com", "another one")
  |> should.equal(Error(user.EmailTaken))
  accounts.register(accounts, "bob@example.com", "short")
  |> should.equal(Error(user.PasswordTooShort))

  accounts.authenticate(accounts, "ada@example.com", "correct horse")
  |> should.equal(Ok(ada))
  accounts.authenticate(accounts, "ada@example.com", "wrong")
  |> should.equal(Error(Nil))
  accounts.authenticate(accounts, "nobody@example.com", "correct horse")
  |> should.equal(Error(Nil))
}

pub fn profile_and_avatar_test() {
  let accounts = accounts.new(memory_users.start(), clock.system())
  let assert Ok(ada) =
    accounts.register(accounts, "ada@example.com", "password1")
  let assert Ok(updated) =
    accounts.update_profile(accounts, ada.id, "Ada L", "Counts things")
  updated.display_name |> should.equal("Ada L")
  accounts.set_avatar(accounts, ada.id, "1-a.png") |> should.equal(Ok(None))
  accounts.set_avatar(accounts, ada.id, "1-b.png")
  |> should.equal(Ok(Some("1-a.png")))
}

import gleam/bit_array
import gleam/string
import gleeunit/should
import gloss/password

pub fn hash_and_verify_test() {
  let stored = password.hash("correct horse")
  password.verify("correct horse", stored) |> should.be_true
  password.verify("wrong horse", stored) |> should.be_false
  password.verify("", stored) |> should.be_false
  string.starts_with(stored, "pbkdf2-sha256$100000$") |> should.be_true
}

pub fn hashes_are_salted_test() {
  should.not_equal(password.hash("same"), password.hash("same"))
}

pub fn malformed_hashes_never_verify_test() {
  password.verify("x", "garbage") |> should.be_false
  password.verify("x", "pbkdf2-sha256$abc$$") |> should.be_false
  password.verify("x", "md5$1$a$b") |> should.be_false
}

pub fn the_cost_is_read_from_the_hash_test() {
  // A hash made at a lower cost, as an older release might have stored.
  let salt = <<"0123456789abcdef":utf8>>
  let derived = pbkdf2(<<"pw":utf8>>, salt, 1000)
  let stored =
    "pbkdf2-sha256$1000$"
    <> bit_array.base64_encode(salt, False)
    <> "$"
    <> bit_array.base64_encode(derived, False)
  password.verify("pw", stored) |> should.be_true
  password.verify("nope", stored) |> should.be_false
  password.verify("pw", string.replace(stored, "$1000$", "$0$"))
  |> should.be_false
}

@external(erlang, "gloss@password_ffi", "pbkdf2")
fn pbkdf2(password: BitArray, salt: BitArray, iterations: Int) -> BitArray

//// Password hashing with PBKDF2-SHA256, for storing and checking user
//// passwords.
////
//// ```gleam
//// let stored = password.hash("correct horse battery staple")
//// password.verify("correct horse battery staple", stored)  // True
//// ```
////
//// Each hash has its own random salt, and `verify` compares in constant
//// time.
////
//// A hash is stored as `pbkdf2-sha256$<iterations>$<salt>$<hash>`, with the
//// salt and hash in base64, so the cost can be raised later and old hashes
//// still verify.

import gleam/bit_array
import gleam/int
import gleam/string

const iterations = 100_000

/// A salted hash of `password`, safe to store.
pub fn hash(password: String) -> String {
  let salt = random_bytes(16)
  encode(iterations, salt, stretch(password, salt, iterations))
}

/// Whether `password` matches the stored hash, compared in constant time.
pub fn verify(password: String, stored: String) -> Bool {
  case string.split(stored, "$") {
    ["pbkdf2-sha256", rounds, salt, expected] ->
      case
        int.parse(rounds),
        bit_array.base64_decode(salt),
        bit_array.base64_decode(expected)
      {
        Ok(rounds), Ok(salt), Ok(expected) if rounds > 0 ->
          hash_equals(stretch(password, salt, rounds), expected)
        _, _, _ -> False
      }
    _ -> False
  }
}

fn stretch(password: String, salt: BitArray, rounds: Int) -> BitArray {
  pbkdf2(bit_array.from_string(password), salt, rounds)
}

fn encode(rounds: Int, salt: BitArray, derived: BitArray) -> String {
  "pbkdf2-sha256$"
  <> int.to_string(rounds)
  <> "$"
  <> bit_array.base64_encode(salt, False)
  <> "$"
  <> bit_array.base64_encode(derived, False)
}

@external(erlang, "gloss@password_ffi", "pbkdf2")
fn pbkdf2(password: BitArray, salt: BitArray, iterations: Int) -> BitArray

@external(erlang, "gloss@password_ffi", "random_bytes")
fn random_bytes(n: Int) -> BitArray

@external(erlang, "gloss@password_ffi", "hash_equals")
fn hash_equals(a: BitArray, b: BitArray) -> Bool

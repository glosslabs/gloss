//// The client side of SCRAM-SHA-256 (RFC 5802, RFC 7677), the password
//// exchange Postgres uses by default. Channel binding is not used.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gloss/internal/runtime

pub type Client {
  Client(nonce: String, first_bare: String)
}

/// The client-first message for `nonce`. Postgres ignores the user name
/// here and uses the one from the startup message, so it is usually empty.
pub fn client_first(user: String, nonce: String) -> #(String, Client) {
  let first_bare = "n=" <> user <> ",r=" <> nonce
  #("n,," <> first_bare, Client(nonce:, first_bare:))
}

/// A fresh client nonce.
pub fn nonce() -> String {
  crypto.strong_random_bytes(18) |> bit_array.base64_encode(True)
}

/// The client-final message answering `server_first`, and the server
/// signature to expect in the server-final message.
pub fn client_final(
  client: Client,
  password: String,
  server_first: String,
) -> Result(#(String, BitArray), Nil) {
  let attributes = parse_attributes(server_first)
  use server_nonce <- result.try(list.key_find(attributes, "r"))
  use salt <- result.try(
    list.key_find(attributes, "s") |> result.try(bit_array.base64_decode),
  )
  use iterations <- result.try(
    list.key_find(attributes, "i") |> result.try(int.parse),
  )
  use <- guard(string.starts_with(server_nonce, client.nonce) && iterations > 0)

  let salted = runtime.pbkdf2_sha256(<<password:utf8>>, salt, iterations, 32)
  let client_key = crypto.hmac(<<"Client Key":utf8>>, crypto.Sha256, salted)
  let stored_key = crypto.hash(crypto.Sha256, client_key)
  let without_proof = "c=biws,r=" <> server_nonce
  let auth_message =
    client.first_bare <> "," <> server_first <> "," <> without_proof
  let signature = crypto.hmac(<<auth_message:utf8>>, crypto.Sha256, stored_key)
  let proof = exor(client_key, signature)
  let server_key = crypto.hmac(<<"Server Key":utf8>>, crypto.Sha256, salted)
  let server_signature =
    crypto.hmac(<<auth_message:utf8>>, crypto.Sha256, server_key)
  Ok(#(
    without_proof <> ",p=" <> bit_array.base64_encode(proof, True),
    server_signature,
  ))
}

/// Whether the server-final message proves the server knows the password.
pub fn verify(server_final: String, expected: BitArray) -> Bool {
  case list.key_find(parse_attributes(server_final), "v") {
    Ok(signature) ->
      bit_array.base64_decode(signature)
      |> result.map(crypto.secure_compare(_, expected))
      |> result.unwrap(False)
    Error(Nil) -> False
  }
}

fn parse_attributes(message: String) -> List(#(String, String)) {
  string.split(message, ",")
  |> list.filter_map(fn(attribute) { string.split_once(attribute, "=") })
}

fn guard(condition: Bool, next: fn() -> Result(a, Nil)) -> Result(a, Nil) {
  case condition {
    True -> next()
    False -> Error(Nil)
  }
}

@external(erlang, "crypto", "exor")
fn exor(a: BitArray, b: BitArray) -> BitArray

//// The password scrambles MySQL's authentication plugins expect.

import gleam/crypto
import gleam/int

/// `mysql_native_password`:
/// `SHA1(password) XOR SHA1(scramble <> SHA1(SHA1(password)))`.
pub fn native_password(password: String, scramble: BitArray) -> BitArray {
  case password {
    "" -> <<>>
    _ -> {
      let stage1 = crypto.hash(crypto.Sha1, <<password:utf8>>)
      let stage2 = crypto.hash(crypto.Sha1, stage1)
      xor(stage1, crypto.hash(crypto.Sha1, <<scramble:bits, stage2:bits>>))
    }
  }
}

/// `caching_sha2_password`'s fast path:
/// `SHA256(password) XOR SHA256(SHA256(SHA256(password)) <> scramble)`.
pub fn caching_sha2(password: String, scramble: BitArray) -> BitArray {
  case password {
    "" -> <<>>
    _ -> {
      let stage1 = crypto.hash(crypto.Sha256, <<password:utf8>>)
      let stage2 = crypto.hash(crypto.Sha256, stage1)
      xor(stage1, crypto.hash(crypto.Sha256, <<stage2:bits, scramble:bits>>))
    }
  }
}

/// What caching_sha2_password's full authentication encrypts with the
/// server's public key: the zero-terminated password XORed with the
/// scramble, repeated as needed.
pub fn obfuscated(password: String, scramble: BitArray) -> BitArray {
  xor(<<password:utf8, 0>>, scramble)
}

/// `data` XOR `key`, the key repeated to `data`'s length.
pub fn xor(data: BitArray, key: BitArray) -> BitArray {
  xor_loop(data, key, key, <<>>)
}

fn xor_loop(
  data: BitArray,
  key: BitArray,
  remaining: BitArray,
  acc: BitArray,
) -> BitArray {
  case data, remaining {
    <<d, data:bits>>, <<k, remaining:bits>> -> {
      let byte = int.bitwise_exclusive_or(d, k)
      xor_loop(data, key, remaining, <<acc:bits, byte>>)
    }
    <<_, _:bits>>, <<>> -> xor_loop(data, key, key, acc)
    _, _ -> acc
  }
}

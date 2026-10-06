-module(gloss@password_ffi).
-export([pbkdf2/3]).

%% gleam_crypto has no key derivation, so PBKDF2 comes from OTP directly.
pbkdf2(Password, Salt, Iterations) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, 32).

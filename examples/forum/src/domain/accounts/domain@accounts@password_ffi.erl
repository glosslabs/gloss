-module(domain@accounts@password_ffi).
-export([pbkdf2/3, random_bytes/1, hash_equals/2]).

%% --- Passwords ----------------------------------------------------------------

pbkdf2(Password, Salt, Iterations) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, 32).

random_bytes(N) -> crypto:strong_rand_bytes(N).

%% Constant-time comparison, so timing doesn't reveal how much matched.
hash_equals(A, B) when byte_size(A) =:= byte_size(B) -> crypto:hash_equals(A, B);
hash_equals(_, _) -> false.

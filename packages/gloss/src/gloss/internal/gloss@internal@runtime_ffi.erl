-module('gloss@internal@runtime_ffi').
-export([try_send/2, monotonic_ns/0, pbkdf2_sha256/4]).

%% gleam@erlang@process:send/2 asserts that a named subject's name is
%% registered. Sending to a process that is gone, or a name nobody holds,
%% is not a crash here.
try_send(Subject, Message) ->
    try 'gleam@erlang@process':send(Subject, Message), true
    catch _:_ -> false
    end.

monotonic_ns() -> erlang:monotonic_time(nanosecond).

%% gleam_crypto has no key derivation, so PBKDF2 comes from OTP directly.
pbkdf2_sha256(Password, Salt, Iterations, Length) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, Length).

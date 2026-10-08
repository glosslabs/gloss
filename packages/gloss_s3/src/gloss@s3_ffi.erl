-module('gloss@s3_ffi').
-export([monotonic_ns/0]).

monotonic_ns() -> erlang:monotonic_time(nanosecond).

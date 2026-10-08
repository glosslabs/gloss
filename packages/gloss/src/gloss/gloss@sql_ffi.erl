-module(gloss@sql_ffi).
-export([rescue/1, reraise/1, new_counter/0, get/1, put/2]).

%% Run F, turning an exception into {error, Crash} so the caller can clean up
%% (roll back, give the connection back) before re-raising it.
rescue(F) ->
    try {ok, F()}
    catch Class:Reason:Stack -> {error, {crash, Class, Reason, Stack}}
    end.

%% Re-raise a crash captured by rescue/1 with its original stacktrace.
reraise({crash, Class, Reason, Stack}) -> erlang:raise(Class, Reason, Stack).

%% A mutable integer: how many levels of a transaction are open.
new_counter() -> atomics:new(1, []).

get(Counter) -> atomics:get(Counter, 1).

put(Counter, Value) -> atomics:put(Counter, 1, Value), nil.

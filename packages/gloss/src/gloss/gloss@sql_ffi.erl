-module(gloss@sql_ffi).
-export([rescue/1, reraise/1, try_send/2]).

%% Run F, turning an exception into {error, Crash} so the caller can clean up
%% (roll back, give the connection back) before re-raising it.
rescue(F) ->
    try {ok, F()}
    catch Class:Reason:Stack -> {error, {crash, Class, Reason, Stack}}
    end.

%% Re-raise a crash captured by rescue/1 with its original stacktrace.
reraise({crash, Class, Reason, Stack}) -> erlang:raise(Class, Reason, Stack).

%% gleam@erlang@process:send/2 asserts that a named subject's name is
%% registered. A stopped pool is an error to report, not a crash.
try_send(Subject, Message) ->
    try 'gleam@erlang@process':send(Subject, Message), true
    catch _:_ -> false
    end.

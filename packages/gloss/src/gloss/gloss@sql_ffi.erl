-module(gloss@sql_ffi).
-export([rescue/1, reraise/1]).

%% Run F, turning an exception into {error, Crash} so the caller can clean up
%% (roll back, give the connection back) before re-raising it.
rescue(F) ->
    try {ok, F()}
    catch Class:Reason:Stack -> {error, {crash, Class, Reason, Stack}}
    end.

%% Re-raise a crash captured by rescue/1 with its original stacktrace.
reraise({crash, Class, Reason, Stack}) -> erlang:raise(Class, Reason, Stack).

-module(gloss@database@sql_ffi).
-export([rescue/1, reraise/1, row/1, coerce/1, timestamp/1, date/1,
         time_of_day/1, try_send/2]).

%% Run F, turning an exception into {error, Crash} so the caller can clean up
%% (roll back, give the connection back) before re-raising it.
rescue(F) ->
    try {ok, F()}
    catch Class:Reason:Stack -> {error, {crash, Class, Reason, Stack}}
    end.

%% Re-raise a crash captured by rescue/1 with its original stacktrace.
reraise({crash, Class, Reason, Stack}) -> erlang:raise(Class, Reason, Stack).

%% Rows are tuples so `decode.field(N, ..)` reaches any column; the stdlib
%% only indexes the first eight elements of a list.
row(Cells) -> list_to_tuple(Cells).

coerce(Value) -> Value.

%% The gleam_time records a driver puts in a row.
timestamp({timestamp, S, N} = T) when is_integer(S), is_integer(N) -> {ok, T};
timestamp(_) -> {error, nil}.

date({date, Y, M, D} = V) when is_integer(Y), is_atom(M), is_integer(D) ->
    {ok, V};
date(_) -> {error, nil}.

time_of_day({time_of_day, H, M, S, N} = V)
  when is_integer(H), is_integer(M), is_integer(S), is_integer(N) -> {ok, V};
time_of_day(_) -> {error, nil}.

%% gleam@erlang@process:send/2 asserts that a named subject's name is
%% registered. A stopped pool is an error to report, not a crash.
try_send(Subject, Message) ->
    try 'gleam@erlang@process':send(Subject, Message), true
    catch _:_ -> false
    end.

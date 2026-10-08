-module(gloss_sql_ffi).
-export([row/1, coerce/1, timestamp/1, date/1, time_of_day/1]).

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

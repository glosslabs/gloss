-module(gloss_otel_ffi).
-export([try_send/2]).

%% gleam@erlang@process:send/2 asserts that a named subject's name is
%% registered. Tracer handlers must never panic, so swallow that here.
try_send(Subject, Message) ->
    try 'gleam@erlang@process':send(Subject, Message) catch _:_ -> nil end,
    nil.

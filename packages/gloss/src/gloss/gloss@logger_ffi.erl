-module(gloss@logger_ffi).
-export([log/3]).

%% Forward a gloss log entry to OTP's logger. Level is one of the atoms
%% debug | info | warning | error. Meta is a Gleam `meta.Meta`: a list of
%% {Key :: binary(), {string, binary()} | {int, integer()} | {float, float()}
%% | {bool, boolean()}}. Keys become atoms so the map matches
%% logger:metadata(); a key that cannot be an atom is kept as a binary.
log(Level, Message, Meta) ->
    logger:log(Level, Message, maps:from_list([{key(K), value(V)} || {K, V} <- Meta])),
    nil.

key(K) ->
    try binary_to_atom(K, utf8) catch _:_ -> K end.

value({string, S}) -> S;
value({int, I}) -> I;
value({float, F}) -> F;
value({bool, B}) -> B.

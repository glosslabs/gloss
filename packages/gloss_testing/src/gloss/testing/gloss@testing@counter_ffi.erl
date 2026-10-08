-module('gloss@testing@counter_ffi').
-export([new/1, get/1, put/2, add/2]).

%% One signed 64-bit integer that any process may read and change.

new(Value) ->
    Ref = atomics:new(1, [{signed, true}]),
    atomics:put(Ref, 1, Value),
    Ref.

get(Ref) -> atomics:get(Ref, 1).

put(Ref, Value) -> atomics:put(Ref, 1, Value), nil.

add(Ref, N) -> atomics:add_get(Ref, 1, N).

-module('gloss@redis_ffi').
-export([counter_new/0, counter_next/2, pick/2, tuple_from_list/1,
         pool_put/2, pool_get/1]).

%% Round robin over a pool's connections.
counter_new() -> counters:new(1, [write_concurrency]).

counter_next(Counter, Size) ->
    counters:add(Counter, 1, 1),
    counters:get(Counter, 1) rem Size.

pick(Tuple, Index) -> element(Index + 1, Tuple).

tuple_from_list(List) -> list_to_tuple(List).

%% A named pool's connections, so handles made with from_name find the
%% current ones across restarts.
pool_put(Name, Pool) -> persistent_term:put({gloss_redis, Name}, Pool), nil.

pool_get(Name) ->
    try {ok, persistent_term:get({gloss_redis, Name})}
    catch error:badarg -> {error, nil}
    end.


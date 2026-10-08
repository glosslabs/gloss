-module(bench@services_ffi).
-export([new_counter/0, next/1]).

new_counter() -> atomics:new(1, []).

next(Counter) -> atomics:add_get(Counter, 1, 1).

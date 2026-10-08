-module('gloss@tracer_ffi').
-export([current/0, with_current/2, random_hex/1]).

-define(KEY, gloss_tracer_current).

current() ->
    case erlang:get(?KEY) of
        undefined -> none;
        Context -> {some, Context}
    end.

%% Run Work with Context as the current span, restoring the previous one
%% afterwards, even if Work raises.
with_current(Context, Work) ->
    Previous = erlang:put(?KEY, Context),
    try Work()
    after
        case Previous of
            undefined -> erlang:erase(?KEY);
            _ -> erlang:put(?KEY, Previous)
        end
    end.

%% Random bytes as lowercase hex, for trace and span ids.
random_hex(Bytes) -> binary:encode_hex(crypto:strong_rand_bytes(Bytes), lowercase).

-module('gloss@tracer_ffi').
-export([current/0, with_current/2]).

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

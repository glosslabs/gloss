-module(gloss@http@session@memory_ffi).
-export([new_table/0, lookup/2, insert/4, delete/2, sweep/2]).

%% An unnamed public ETS table, so request processes read and write it
%% directly; the owning process only keeps it alive and sweeps it.

new_table() ->
    ets:new(gloss_sessions, [set, public, {read_concurrency, true},
                             {write_concurrency, true}]).

%% {ok, {Data, ExpiresAt}} | {error, nil}. ExpiresAt is in milliseconds.
lookup(Table, Id) ->
    try ets:lookup(Table, Id) of
        [{_, Data, ExpiresAt}] -> {ok, {Data, ExpiresAt}};
        [] -> {error, nil}
    catch
        error:badarg -> {error, nil}
    end.

insert(Table, Id, Data, ExpiresAt) ->
    try ets:insert(Table, {Id, Data, ExpiresAt}) catch error:badarg -> true end,
    nil.

delete(Table, Id) ->
    try ets:delete(Table, Id) catch error:badarg -> true end,
    nil.

%% Delete every session that expired before Now; returns how many.
sweep(Table, Now) ->
    ets:select_delete(Table, [{{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}]).

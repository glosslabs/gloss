-module('gloss@http@debug_bar_ffi').
-export([new_table/0, insert/4, lookup/2, recent/2, sweep/2]).

%% Rows are {TraceId, Seq, InsertedMs, IsRequest, Item} in a public bag, so
%% any process adds to a trace with one atomic insert.

new_table() ->
    ets:new(gloss_debug_bar, [bag, public, {write_concurrency, true}, {read_concurrency, true}]).

insert(Table, TraceId, IsRequest, Item) ->
    Seq = erlang:unique_integer([monotonic, positive]),
    catch ets:insert(Table, {TraceId, Seq, erlang:system_time(millisecond), IsRequest, Item}),
    nil.

%% A trace's items in the order they were recorded.
lookup(Table, TraceId) ->
    Rows = try ets:lookup(Table, TraceId) catch _:_ -> [] end,
    [Item || {_, _, _, _, Item} <- lists:keysort(2, Rows)].

%% The latest Limit request items, newest first.
recent(Table, Limit) ->
    Rows = try ets:match_object(Table, {'_', '_', '_', true, '_'}) catch _:_ -> [] end,
    Sorted = lists:reverse(lists:keysort(2, Rows)),
    [Item || {_, _, _, _, Item} <- lists:sublist(Sorted, Limit)].

%% Forget everything recorded before CutoffMs.
sweep(Table, CutoffMs) ->
    ets:select_delete(Table, [{{'_', '_', '$1', '_', '_'}, [{'<', '$1', CutoffMs}], [true]}]),
    nil.

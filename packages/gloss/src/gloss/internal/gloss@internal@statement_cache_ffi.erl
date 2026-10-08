-module('gloss@internal@statement_cache_ffi').
-export([new/1, lookup/2, put/3, delete/2, take_closing/1, next_id/1,
         give/2, drop/1]).

%% One public ETS table per connection, so whichever process has borrowed
%% the connection can use it. Rows are {{sql, Sql}, Value, LastUsed};
%% '$tick' counts uses, and '$closing' holds evicted values to close on
%% the server with the next request.

new(Max) ->
    Table = ets:new(gloss_statement_cache, [set, public]),
    ets:insert(Table, [{'$max', Max}, {'$tick', 0}, {'$closing', []}]),
    Table.

lookup(Table, Sql) ->
    case ets:lookup(Table, {sql, Sql}) of
        [{Key, Value, _}] ->
            ets:update_element(Table, Key, {3, tick(Table)}),
            {ok, Value};
        [] -> {error, nil}
    end.

put(Table, Sql, Value) ->
    ets:insert(Table, {{sql, Sql}, Value, tick(Table)}),
    [{_, Max}] = ets:lookup(Table, '$max'),
    case ets:info(Table, size) - 3 > Max of
        true -> evict_oldest(Table);
        false -> ok
    end,
    nil.

delete(Table, Sql) ->
    case ets:lookup(Table, {sql, Sql}) of
        [{Key, Value, _}] -> ets:delete(Table, Key), closing(Table, Value);
        [] -> ok
    end,
    nil.

take_closing(Table) ->
    [{_, Values}] = ets:lookup(Table, '$closing'),
    ets:insert(Table, {'$closing', []}),
    Values.

next_id(Table) -> tick(Table).

give(Table, Pid) -> _ = ets:give_away(Table, Pid, gloss_statement_cache), nil.

drop(Table) -> catch ets:delete(Table), nil.

tick(Table) -> ets:update_counter(Table, '$tick', 1).

closing(Table, Value) ->
    [{_, Values}] = ets:lookup(Table, '$closing'),
    ets:insert(Table, {'$closing', [Value | Values]}).

evict_oldest(Table) ->
    Oldest = ets:foldl(
        fun({{sql, _} = Key, Value, Used}, none) -> {Key, Value, Used};
           ({{sql, _} = Key, Value, Used}, {_, _, Best}) when Used < Best ->
                {Key, Value, Used};
           (_, Best) -> Best
        end, none, Table),
    case Oldest of
        {Key, Value, _} -> ets:delete(Table, Key), closing(Table, Value);
        none -> ok
    end.

-module(gloss@http@session@file_ffi).
-export([open/2, lookup/2, insert/4, delete/2, sweep/2]).

%% Sessions in a public ETS table for reads, written through to a DETS file
%% that refills the table on open. The process that opens them owns both:
%% when it exits the table goes and the file is closed.

open(Path, Now) ->
    File = unicode:characters_to_list(Path),
    case filelib:ensure_dir(File) of
        ok ->
            case dets:open_file(make_ref(), [{file, File}, {type, set},
                                             {repair, true}]) of
                {ok, Dets} ->
                    Ets = ets:new(gloss_sessions, [set, public,
                                                   {read_concurrency, true},
                                                   {write_concurrency, true}]),
                    _ = dets:select_delete(Dets, expired(Now)),
                    _ = dets:to_ets(Dets, Ets),
                    {ok, {Ets, Dets}};
                {error, Reason} ->
                    {error, describe(Reason)}
            end;
        {error, Reason} ->
            {error, describe(Reason)}
    end.

%% {ok, {Data, ExpiresAt}} | {error, nil}. ExpiresAt is in milliseconds.
lookup({Ets, _}, Id) ->
    try ets:lookup(Ets, Id) of
        [{_, Data, ExpiresAt}] -> {ok, {Data, ExpiresAt}};
        [] -> {error, nil}
    catch
        error:badarg -> {error, nil}
    end.

insert({Ets, Dets}, Id, Data, ExpiresAt) ->
    Row = {Id, Data, ExpiresAt},
    try ets:insert(Ets, Row) of
        true -> _ = dets:insert(Dets, Row)
    catch
        error:badarg -> ok
    end,
    nil.

delete({Ets, Dets}, Id) ->
    try ets:delete(Ets, Id) of
        true -> _ = dets:delete(Dets, Id)
    catch
        error:badarg -> ok
    end,
    nil.

%% Delete every session that expired before Now, and flush the file.
sweep({Ets, Dets}, Now) ->
    _ = ets:select_delete(Ets, expired(Now)),
    _ = dets:select_delete(Dets, expired(Now)),
    _ = dets:sync(Dets),
    nil.

expired(Now) ->
    [{{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}].

describe(Reason) ->
    iolist_to_binary(io_lib:format("~0p", [Reason])).

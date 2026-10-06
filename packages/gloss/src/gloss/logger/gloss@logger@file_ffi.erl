-module(gloss@logger@file_ffi).
-export([open/1, write/2, close/1, size/1, rename/2, delete/1, try_send/2]).

%% File primitives for gloss/logger/file. Failures are returned or
%% swallowed, never raised: a log channel must not crash its caller.

open(Path) ->
    _ = filelib:ensure_dir(Path),
    case file:open(Path, [append, raw, binary]) of
        {ok, Device} -> {ok, Device};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

write(Device, Data) ->
    case file:write(Device, Data) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

close(Device) ->
    _ = file:close(Device),
    nil.

size(Path) ->
    filelib:file_size(Path).

rename(From, To) ->
    _ = file:rename(From, To),
    nil.

delete(Path) ->
    _ = file:delete(Path),
    nil.

%% Sending to a named subject whose name is not registered panics in
%% gleam_erlang; a log writer must not, so swallow it.
try_send(Subject, Message) ->
    try 'gleam@erlang@process':send(Subject, Message) catch _:_ -> nil end,
    nil.

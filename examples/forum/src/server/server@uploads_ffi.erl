-module(server@uploads_ffi).
-export([open_write/1, write/2, close/1, rename/2, delete/1, random_name/0]).

%% --- Files ------------------------------------------------------------------

open_write(Path) ->
    _ = filelib:ensure_dir(Path),
    case file:open(Path, [write, raw, binary]) of
        {ok, Device} -> {ok, Device};
        {error, _} -> {error, nil}
    end.

write(Device, Data) ->
    case file:write(Device, Data) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

close(Device) -> _ = file:close(Device), nil.

rename(From, To) ->
    case file:rename(From, To) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

delete(Path) -> _ = file:delete(Path), nil.


%% 16 random hex characters, for file names.
random_name() -> string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(8))).

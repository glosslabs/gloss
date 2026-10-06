-module(upload_test_ffi).
-export([read/1, files/1]).

read(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.

%% Every file in Dir, including hidden ones; [] when Dir doesn't exist.
files(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} -> lists:sort([list_to_binary(N) || N <- Names]);
        {error, _} -> []
    end.

-module(file_test_ffi).
-export([read/1]).

read(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.

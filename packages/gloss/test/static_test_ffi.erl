-module(static_test_ffi).
-export([write/2]).

write(Path, Contents) ->
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Contents),
    nil.

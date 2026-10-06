-module(signal_test_ffi).
-export([kill/1]).

kill(Signal) ->
    os:cmd("kill -" ++ binary_to_list(Signal) ++ " " ++ os:getpid()),
    nil.

-module(bench@harness_ffi).
-export([now_ns/0, loop/2, concurrent/3, black_box/1]).

now_ns() -> erlang:monotonic_time(nanosecond).

%% Call F N times.
loop(_, 0) -> nil;
loop(F, N) -> black_box(F()), loop(F, N - 1).

%% Run F PerWorker times in each of Workers processes; wait for all.
concurrent(F, Workers, PerWorker) ->
    Self = self(),
    Pids = [spawn_link(fun() -> loop(F, PerWorker), Self ! {done, self()} end)
            || _ <- lists:seq(1, Workers)],
    [receive {done, P} -> ok end || P <- Pids],
    nil.

%% Keep a result from being optimised away.
black_box(X) -> erlang:phash2(X, 1), nil.

-module('gloss@reload_ffi').
-export([scan/2, build/2, reload_modified/0]).

%% Look at the files under Dirs again: {Snapshot, ChangedPaths}, where
%% Snapshot is #{Path => {Size, Mtime, Hash}} and Previous is the last one.
%% Modification times only have one-second resolution, so a file changed in
%% the last two seconds is also compared by its contents' hash; otherwise
%% the hash is carried over unread.
scan(Dirs, Previous) ->
    Now = erlang:system_time(second),
    Snapshot = lists:foldl(fun(Dir, Acc) ->
        filelib:fold_files(binary_to_list(Dir), ".*", true, fun(Path, Files) ->
            case file:read_file_info(Path, [{time, posix}]) of
                {ok, Info} when element(3, Info) =:= regular ->
                    Key = unicode:characters_to_binary(Path),
                    Size = element(2, Info),
                    Mtime = element(6, Info),
                    Hash = case {Mtime >= Now - 2, maps:find(Key, Previous)} of
                        {true, _} -> hash(Path);
                        {false, {ok, {Size, Mtime, Old}}} -> Old;
                        {false, _} -> undefined
                    end,
                    maps:put(Key, {Size, Mtime, Hash}, Files);
                _ -> Files
            end
        end, Acc)
    end, #{}, Dirs),
    Changed = [Path || {Path, New} <- maps:to_list(Snapshot), changed(maps:find(Path, Previous), New)]
        ++ [Path || Path <- maps:keys(Previous), not maps:is_key(Path, Snapshot)],
    {Snapshot, lists:sort(Changed)}.

changed(error, _) -> true;
changed({ok, {Size, Mtime, Old}}, {Size, Mtime, New}) ->
    Old =/= undefined andalso New =/= undefined andalso Old =/= New;
changed({ok, _}, _) -> true.

hash(Path) ->
    case file:read_file(Path) of
        {ok, Data} -> erlang:md5(Data);
        _ -> undefined
    end.

%% Run Command (a list of strings, the first the executable) in Dir:
%% {ok, Output} on exit status 0, else {error, Output}.
build([Executable | Args], Dir) ->
    case os:find_executable(binary_to_list(Executable)) of
        false -> {error, <<Executable/binary, " was not found on the PATH">>};
        Path ->
            Port = open_port({spawn_executable, Path},
                [{args, [binary_to_list(A) || A <- Args]}, {cd, binary_to_list(Dir)},
                 exit_status, stderr_to_stdout, binary, hide]),
            collect(Port, [])
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Acc, Data]);
        {Port, {exit_status, 0}} -> {ok, strip(iolist_to_binary(Acc))};
        {Port, {exit_status, _}} -> {error, strip(iolist_to_binary(Acc))}
    end.

%% Drop ANSI colour codes, so output reads cleanly in a browser.
strip(Text) ->
    re:replace(Text, <<"\e\\[[0-9;]*m">>, <<>>, [global, {return, binary}]).

%% Load the new code of every loaded module whose file changed, purging the
%% old code first. Answers the modules reloaded.
reload_modified() ->
    lists:filtermap(fun(Module) ->
        code:purge(Module),
        case code:load_file(Module) of
            {module, Module} -> {true, atom_to_binary(Module)};
            {error, _} -> false
        end
    end, code:modified_modules()).

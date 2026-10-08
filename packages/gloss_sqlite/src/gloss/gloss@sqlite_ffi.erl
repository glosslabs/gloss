-module('gloss@sqlite_ffi').
-export([open/1, run/4, script/3, close/1, alive/1, unique/0, failure/1]).

%% A connection is {Db, State, Lock}. State is atomics: slot 1 is set once
%% the connection is closed or abandoned after a timeout, so every later
%% call fails; slot 2 is set while a transaction is open on it.
%%
%% SQLite allows one writer at a time, and a writer that finds the database
%% locked sleeps for a millisecond or more before trying again. With several
%% pool connections that turns contention into long stalls, so writers queue
%% for Lock, one per database file, in the BEAM instead: a write outside a
%% transaction holds it for the statement, a transaction from BEGIN to
%% COMMIT or ROLLBACK. Reads don't take it.

-define(CLOSED, 1).
-define(IN_TRANSACTION, 2).

open(Filename) ->
    case esqlite3:open(binary_to_list(Filename)) of
        {ok, Db} -> {ok, {Db, atomics:new(2, []), lock_for(Filename)}};
        {error, Code} -> {error, {Code, describe(Code)}}
    end.

close({Db, State, Lock}) ->
    atomics:put(State, ?CLOSED, 1),
    release(Lock, State),
    _ = esqlite3:close(Db),
    nil.

alive({_, State, _}) -> atomics:get(State, ?CLOSED) =:= 0.

%% Run one statement within Timeout milliseconds:
%% {ok, {Decltypes, Rows, Changes}} or {error, {Code, Message}}.
run({Db, State, Lock} = Conn, Sql, Args, Timeout) ->
    case alive(Conn) of
        false -> {error, closed};
        true ->
            Work = fun() -> timed(Conn, Timeout, fun() -> statement(Db, Sql, Args) end) end,
            case atomics:get(State, ?IN_TRANSACTION) =:= 0 andalso writes(Sql) of
                true -> locked(Lock, State, Timeout, Work);
                false -> Work()
            end
    end.

statement(Db, Sql, Args) ->
    case esqlite3:prepare(Db, Sql) of
        {ok, Stmt} ->
            case esqlite3:bind(Stmt, [cell(A) || A <- Args]) of
                ok ->
                    case esqlite3:fetchall(Stmt) of
                        Rows when is_list(Rows) ->
                            Names = esqlite3:column_names(Stmt),
                            Types = [declared(T) || T <- esqlite3:column_decltypes(Stmt)],
                            Changes = case Names of
                                [] -> esqlite3:changes(Db);
                                _ -> length(Rows)
                            end,
                            {ok, {Types, [[tag(C) || C <- Row] || Row <- Rows], Changes}};
                        {error, _} -> last_error(Db)
                    end;
                {error, _} -> last_error(Db)
            end;
        {error, _} -> last_error(Db)
    end.

script({Db, State, Lock} = Conn, Sql, Timeout) ->
    case alive(Conn) of
        false -> {error, closed};
        true ->
            Exec = fun() ->
                timed(Conn, Timeout, fun() ->
                    case esqlite3:exec(Db, Sql) of
                        ok -> {ok, nil};
                        {error, _} -> last_error(Db)
                    end
                end)
            end,
            InTransaction = atomics:get(State, ?IN_TRANSACTION) =:= 1,
            case control(Sql) of
                'begin' when not InTransaction ->
                    case acquire(Lock, State, Timeout) of
                        ok ->
                            case Exec() of
                                {ok, nil} ->
                                    atomics:put(State, ?IN_TRANSACTION, 1),
                                    {ok, nil};
                                Error ->
                                    release(Lock, State),
                                    Error
                            end;
                        timeout -> lock_timeout()
                    end;
                'end' when InTransaction ->
                    case Exec() of
                        {ok, nil} -> finish(Lock, State), {ok, nil};
                        Error -> Error
                    end;
                rollback when InTransaction ->
                    Result = Exec(),
                    finish(Lock, State),
                    Result;
                _ when not InTransaction ->
                    case writes(Sql) of
                        true -> locked(Lock, State, Timeout, Exec);
                        false -> Exec()
                    end;
                _ -> Exec()
            end
    end.

finish(Lock, State) ->
    atomics:put(State, ?IN_TRANSACTION, 0),
    release(Lock, State).

locked(Lock, State, Timeout, Work) ->
    case acquire(Lock, State, Timeout) of
        ok ->
            try Work() after release(Lock, State) end;
        timeout -> lock_timeout()
    end.

lock_timeout() -> {error, {5, <<"timed out waiting to write">>}}.

%% Interrupt the statement if it runs past Timeout, then close the
%% connection: SQLite reports SQLITE_INTERRUPT (9).
timed({Db, _, _} = Conn, Timeout, Work) ->
    Self = self(),
    Ref = make_ref(),
    Timer = spawn(fun() ->
        receive {Ref, done} -> ok
        after Timeout ->
            esqlite3:interrupt(Db),
            Self ! {Ref, interrupted}
        end
    end),
    Result = Work(),
    Timer ! {Ref, done},
    receive
        {Ref, interrupted} ->
            close(Conn),
            {error, {9, <<"interrupted after the query timeout">>}}
    after 0 -> Result
    end.

%% --- Statement kinds ----------------------------------------------------------

%% Transaction control: 'begin', 'end' (COMMIT or END), rollback (but not
%% ROLLBACK TO a savepoint), or other.
control(Sql) ->
    case words(Sql, 2) of
        [<<"BEGIN">> | _] -> 'begin';
        [<<"COMMIT">> | _] -> 'end';
        [<<"END">> | _] -> 'end';
        [<<"ROLLBACK">>, <<"TO">>] -> other;
        [<<"ROLLBACK">>, <<"TRANSACTION">>] -> rollback;
        [<<"ROLLBACK">>] -> rollback;
        [<<"ROLLBACK">>, _] -> other;
        _ -> other
    end.

%% Whether a statement changes the database, by its first word.
writes(Sql) ->
    case words(Sql, 1) of
        [W] -> lists:member(W, [<<"INSERT">>, <<"UPDATE">>, <<"DELETE">>,
                                <<"REPLACE">>, <<"CREATE">>, <<"DROP">>,
                                <<"ALTER">>, <<"VACUUM">>, <<"REINDEX">>]);
        _ -> false
    end.

%% The first N words, upper-cased. A plain scan: this runs for every
%% statement, and compiling a split pattern each time costs more.
words(Sql, N) -> words(Sql, N, []).

words(_, 0, Acc) -> lists:reverse(Acc);
words(Sql, N, Acc) ->
    case word(skip_space(Sql), <<>>) of
        {<<>>, _} -> lists:reverse(Acc);
        {Word, Rest} -> words(Rest, N - 1, [string:uppercase(Word) | Acc])
    end.

skip_space(<<C, Rest/binary>>) when C =:= $\s; C =:= $\n; C =:= $\t; C =:= $\r; C =:= $; ->
    skip_space(Rest);
skip_space(Sql) -> Sql.

word(<<C, _/binary>> = Rest, Acc) when C =:= $\s; C =:= $\n; C =:= $\t; C =:= $\r; C =:= $; ->
    {Acc, Rest};
word(<<C, Rest/binary>>, Acc) -> word(Rest, <<Acc/binary, C>>);
word(<<>>, Acc) -> {Acc, <<>>}.

%% --- The write lock -------------------------------------------------------------

%% The lock process for a database file, started on first use.
lock_for(Filename) ->
    Name = list_to_atom("gloss_sqlite_lock_" ++ integer_to_list(erlang:phash2(Filename))),
    case whereis(Name) of
        undefined ->
            spawn(fun() ->
                try register(Name, self()) of
                    true -> lock_loop(none, [])
                catch error:badarg -> ok
                end
            end),
            wait_for(Name, 100);
        Pid -> Pid
    end.

wait_for(Name, 0) -> error({no_lock_process, Name});
wait_for(Name, Tries) ->
    case whereis(Name) of
        undefined -> timer:sleep(1), wait_for(Name, Tries - 1);
        Pid -> Pid
    end.

%% Holder is none or {Pid, Key, Tag, Monitor}; Waiting is oldest first.
lock_loop(Holder, Waiting) ->
    receive
        {acquire, From, Key, Tag} ->
            case Holder of
                none -> grant({From, Key, Tag}, Waiting);
                _ -> lock_loop(Holder, Waiting ++ [{From, Key, Tag}])
            end;
        {release, Key} ->
            case Holder of
                {_, Key, _, Monitor} ->
                    erlang:demonitor(Monitor, [flush]),
                    next(Waiting);
                _ -> lock_loop(Holder, Waiting)
            end;
        {cancel, From, Tag} ->
            From ! {Tag, cancelled},
            case Holder of
                {From, _, Tag, Monitor} ->
                    erlang:demonitor(Monitor, [flush]),
                    next(Waiting);
                _ -> lock_loop(Holder, [W || {_, _, T} = W <- Waiting, T =/= Tag])
            end;
        {'DOWN', Monitor, process, _, _} ->
            case Holder of
                {_, _, _, Monitor} -> next(Waiting);
                _ -> lock_loop(Holder, Waiting)
            end
    end.

next([]) -> lock_loop(none, []);
next([{From, _, _} = Waiter | Rest]) ->
    case is_process_alive(From) of
        true -> grant(Waiter, Rest);
        false -> next(Rest)
    end.

grant({From, Key, Tag}, Waiting) ->
    Monitor = erlang:monitor(process, From),
    From ! {Tag, granted},
    lock_loop({From, Key, Tag, Monitor}, Waiting).

%% Wait up to Timeout milliseconds for the lock: ok or timeout.
acquire(Lock, Key, Timeout) ->
    Tag = make_ref(),
    Lock ! {acquire, self(), Key, Tag},
    receive
        {Tag, granted} -> ok
    after Timeout ->
        %% The grant may be on its way; the lock answers the cancel either
        %% way, releasing the lock if it had been granted.
        Lock ! {cancel, self(), Tag},
        receive {Tag, cancelled} -> ok end,
        receive {Tag, granted} -> ok after 0 -> ok end,
        timeout
    end.

release(Lock, Key) -> Lock ! {release, Key}, nil.

%% --- Values ---------------------------------------------------------------------

last_error(Db) ->
    #{extended_errcode := Code, errmsg := Message} = esqlite3:error_info(Db),
    {error, {Code, Message}}.

describe(Code) -> iolist_to_binary(io_lib:format("sqlite error ~p", [Code])).

declared(undefined) -> <<>>;
declared(Type) -> Type.

%% Arguments as esqlite binds them.
cell(null) -> undefined;
cell({integer, I}) -> I;
cell({real, F}) -> F;
cell({text, S}) -> {text, S};
cell({blob, B}) -> {blob, B}.

%% Column values as gloss/sql/internal/sqlite cells.
tag(undefined) -> null;
tag(I) when is_integer(I) -> {integer, I};
tag(F) when is_float(F) -> {real, F};
tag(B) when is_binary(B) -> {binary, B}.

unique() -> erlang:unique_integer([positive]).

failure({Code, Message}) when is_integer(Code) -> {ok, {Code, Message}};
failure(_) -> {error, nil}.

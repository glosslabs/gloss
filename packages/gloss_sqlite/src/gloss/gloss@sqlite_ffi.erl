-module('gloss@sqlite_ffi').
-export([open/1, run/4, script/3, close/1, alive/1, unique/0, failure/1]).

%% A connection is {Db, Flag}: Flag is set once the connection is closed or
%% abandoned after a timeout, so every later call fails.

open(Filename) ->
    case esqlite3:open(binary_to_list(Filename)) of
        {ok, Db} -> {ok, {Db, atomics:new(1, [])}};
        {error, Code} -> {error, {Code, describe(Code)}}
    end.

close({Db, Flag}) ->
    atomics:put(Flag, 1, 1),
    _ = esqlite3:close(Db),
    nil.

alive({_, Flag}) -> atomics:get(Flag, 1) =:= 0.

%% Run one statement within Timeout milliseconds:
%% {ok, {Decltypes, Rows, Changes, HasColumns}} or {error, {Code, Message}}.
run({Db, Flag} = Conn, Sql, Args, Timeout) ->
    case alive(Conn) of
        false -> {error, closed};
        true ->
            timed(Conn, Timeout, fun() ->
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
                end
            end, Flag)
    end.

script({Db, Flag} = Conn, Sql, Timeout) ->
    case alive(Conn) of
        false -> {error, closed};
        true ->
            timed(Conn, Timeout, fun() ->
                case esqlite3:exec(Db, Sql) of
                    ok -> {ok, nil};
                    {error, _} -> last_error(Db)
                end
            end, Flag)
    end.

%% Interrupt the statement if it runs past Timeout, then close the
%% connection: SQLite reports SQLITE_INTERRUPT (9).
timed({Db, _} = Conn, Timeout, Work, _Flag) ->
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

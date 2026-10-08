-module('gloss@sentry_crash_ffi').
-export([install/1, uninstall/0, log/2, describe/2]).

%% An OTP logger handler that hands process crashes to a Gleam function.
%% It runs in the process that logs the crash, so it does no more than
%% pick the crash apart and call `Report`, which sends one message.

-define(ID, gloss_sentry_crashes).

install(Report) ->
    _ = logger:remove_handler(?ID),
    case logger:add_handler(?ID, ?MODULE, #{level => error, config => #{report => Report}}) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

uninstall() ->
    _ = logger:remove_handler(?ID),
    nil.

log(#{msg := Msg, meta := Meta}, #{config := #{report := Report}}) ->
    case maps:get(gloss_traced, Meta, false) of
        true -> ok;
        false ->
            case crash(Msg, Meta) of
                {ok, Crash} -> catch Report(Crash), ok;
                skip -> ok
            end
    end;
log(_, _) ->
    ok.

%% A process started with proc_lib (gen_server, gleam_otp actors, Gleam's
%% process.spawn) that raised or exited abnormally.
crash({report, #{label := {proc_lib, crash}, report := [Info | _]}}, _) when is_list(Info) ->
    case proplists:get_value(error_info, Info) of
        {Class, Reason, Stack} when is_list(Stack) ->
            Name = case proplists:get_value(registered_name, Info) of
                [] -> undefined;
                N -> N
            end,
            {ok, crash_tuple(Class, Reason, Stack, proplists:get_value(pid, Info), Name,
                             proplists:get_value(initial_call, Info))};
        _ -> skip
    end;
%% A process started with erlang:spawn that raised.
crash({"Error in process ~p with exit value:~n~p~n", [Pid, {Reason, Stack}]}, _) when is_list(Stack) ->
    {ok, crash_tuple(error, Reason, Stack, Pid, undefined, undefined)};
crash({"Error in process ~p on node ~p with exit value:~n~p~n", [Pid, _, {Reason, Stack}]}, _) when is_list(Stack) ->
    {ok, crash_tuple(error, Reason, Stack, Pid, undefined, undefined)};
crash(_, _) ->
    skip.

%% {crash, Type, Value, Frames, Process, InitialCall}, as gloss_sentry's
%% internal Crash type.
crash_tuple(Class, Reason, Stack, Pid, Name, InitialCall) ->
    {Type, Value} = describe(Class, Reason),
    Process = case Name of
        undefined when is_pid(Pid) -> list_to_binary(pid_to_list(Pid));
        undefined -> <<"unknown">>;
        _ -> atom_to_binary(Name)
    end,
    Initial = case InitialCall of
        {M, F, A} when is_list(A) -> mfa(M, F, length(A));
        {M, F, A} when is_integer(A) -> mfa(M, F, A);
        _ -> <<"">>
    end,
    {crash, Type, Value, frames(Stack), Process, Initial}.

%% The exception's type and value. A Gleam panic, todo or failed assertion
%% is named by its kind, with its message and where it happened.
describe(error, #{gleam_error := Kind, message := Message} = Error) ->
    Where = case Error of
        #{module := M, function := F, line := L} ->
            iolist_to_binary([" (", M, ".", F, ":", integer_to_binary(L), ")"]);
        _ -> <<>>
    end,
    {atom_to_binary(Kind), iolist_to_binary([Message, Where])};
describe(error, Reason) when is_atom(Reason) ->
    {atom_to_binary(Reason), atom_to_binary(Reason)};
describe(error, Reason) when is_tuple(Reason), tuple_size(Reason) > 0, is_atom(element(1, Reason)) ->
    {atom_to_binary(element(1, Reason)), format(Reason)};
describe(error, Reason) ->
    {<<"error">>, format(Reason)};
describe(exit, Reason) ->
    {<<"exit">>, format(Reason)};
describe(throw, Reason) ->
    {<<"nocatch">>, format(Reason)}.

format(Term) ->
    unicode:characters_to_binary(io_lib:format("~0tP", [Term, 12])).

%% Oldest call first, as Sentry expects. Gleam modules (app@worker) are
%% shown by their Gleam name (app/worker).
frames(Stack) ->
    lists:reverse([frame(M, F, A, Location) || {M, F, A, Location} <- Stack]).

frame(M, F, A, Location) ->
    Arity = case A of
        Args when is_list(Args) -> length(Args);
        N -> N
    end,
    File = case proplists:get_value(file, Location) of
        undefined -> <<"">>;
        Path -> unicode:characters_to_binary(Path)
    end,
    Line = case proplists:get_value(line, Location) of
        undefined -> 0;
        L -> L
    end,
    {gleam_name(M), iolist_to_binary([atom_to_binary(F), "/", integer_to_binary(Arity)]),
     File, Line}.

mfa(M, F, A) ->
    iolist_to_binary([gleam_name(M), ".", atom_to_binary(F), "/", integer_to_binary(A)]).

gleam_name(Module) ->
    binary:replace(atom_to_binary(Module), <<"@">>, <<"/">>, [global]).

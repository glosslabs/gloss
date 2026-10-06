-module(gloss@signal_ffi).
-behaviour(gen_event).

-export([subscribe/1]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2,
         code_change/3]).

%% Route SIGTERM and SIGHUP to Gleam subjects instead of the default
%% erl_signal_handler (which calls init:stop() on SIGTERM). The first
%% subscription swaps this module in; later ones are added to its state.
subscribe(Subject) ->
    ok = os:set_signal(sigterm, handle),
    ok = os:set_signal(sighup, handle),
    Handlers = gen_event:which_handlers(erl_signal_server),
    case lists:member(?MODULE, Handlers) of
        true ->
            ok = gen_event:call(erl_signal_server, ?MODULE, {subscribe, Subject});
        false ->
            ok = gen_event:swap_handler(
                erl_signal_server,
                {erl_signal_handler, []},
                {?MODULE, [Subject]}
            )
    end,
    nil.

%% Called by swap_handler with {Args, OldHandlerTerminateResult}, or by
%% add_handler with Args alone.
init({Subjects, _}) when is_list(Subjects) -> {ok, Subjects};
init(Subjects) when is_list(Subjects) -> {ok, Subjects}.

handle_event(sigterm, Subjects) ->
    case [S || S <- Subjects, alive(S)] of
        [] -> init:stop();
        Alive -> [send(S, terminate) || S <- Alive]
    end,
    {ok, Subjects};
handle_event(sighup, Subjects) ->
    [send(S, hangup) || S <- Subjects, alive(S)],
    {ok, Subjects};
handle_event(_, Subjects) ->
    {ok, Subjects}.

handle_call({subscribe, Subject}, Subjects) ->
    {ok, ok, [Subject | [S || S <- Subjects, alive(S)]]}.

handle_info(_, Subjects) -> {ok, Subjects}.

terminate(_, _) -> ok.

code_change(_, Subjects, _) -> {ok, Subjects}.

send(Subject, Message) -> 'gleam@erlang@process':send(Subject, Message).

alive(Subject) ->
    case 'gleam@erlang@process':subject_owner(Subject) of
        {ok, Pid} -> is_process_alive(Pid);
        {error, nil} -> false
    end.

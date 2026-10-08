-module('gloss@redis_ffi').
-export([connect/5, send/2, recv/2, activate/1, close/1, socket_message/2,
         counter_new/0, counter_next/2, pick/2, tuple_from_list/1,
         pool_put/2, pool_get/1, try_send/2]).

%% A socket is {tcp, Port} or {ssl, SslSocket}, so callers needn't care
%% which. Sockets start passive, for the handshake, then turn active.

connect(Host, Port, Tls, Verify, Timeout) ->
    Options = [binary, {active, false}, {packet, raw}, {nodelay, true},
               {keepalive, true}],
    Name = binary_to_list(Host),
    case Tls of
        false ->
            case gen_tcp:connect(Name, Port, Options, Timeout) of
                {ok, Socket} -> {ok, {tcp, Socket}};
                {error, Reason} -> {error, describe(Reason)}
            end;
        true ->
            {ok, _} = application:ensure_all_started(ssl),
            TlsOptions = case Verify of
                true ->
                    [{verify, verify_peer},
                     {cacerts, public_key:cacerts_get()},
                     {server_name_indication, Name},
                     {customize_hostname_check,
                      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}];
                false -> [{verify, verify_none}]
            end,
            case ssl:connect(Name, Port, Options ++ TlsOptions, Timeout) of
                {ok, Socket} -> {ok, {ssl, Socket}};
                {error, Reason} -> {error, describe(Reason)}
            end
    end.

send({tcp, Socket}, Data) -> sent(gen_tcp:send(Socket, Data));
send({ssl, Socket}, Data) -> sent(ssl:send(Socket, Data)).

sent(ok) -> {ok, nil};
sent({error, Reason}) -> {error, describe(Reason)}.

%% A passive read, for the handshake.
recv({tcp, Socket}, Timeout) -> received(gen_tcp:recv(Socket, 0, Timeout));
recv({ssl, Socket}, Timeout) -> received(ssl:recv(Socket, 0, Timeout)).

received({ok, Data}) -> {ok, Data};
received({error, Reason}) -> {error, describe(Reason)}.

%% Deliver everything that arrives as messages to the owner.
activate({tcp, Socket}) -> _ = inet:setopts(Socket, [{active, true}]), nil;
activate({ssl, Socket}) -> _ = ssl:setopts(Socket, [{active, true}]), nil.

close({tcp, Socket}) -> _ = gen_tcp:close(Socket), nil;
close({ssl, Socket}) -> _ = ssl:close(Socket), nil.

%% What a message means for Socket: {data, Bytes}, closed, {failed,
%% Reason}, or other for anything else.
socket_message({tcp, S}, {tcp, S, Data}) -> {data, Data};
socket_message({ssl, S}, {ssl, S, Data}) -> {data, Data};
socket_message({tcp, S}, {tcp_closed, S}) -> closed;
socket_message({ssl, S}, {ssl_closed, S}) -> closed;
socket_message({tcp, S}, {tcp_error, S, R}) -> {failed, describe(R)};
socket_message({ssl, S}, {ssl_error, S, R}) -> {failed, describe(R)};
socket_message(_, _) -> other.

describe(Reason) when is_atom(Reason) ->
    case inet:format_error(Reason) of
        "unknown POSIX error" ++ _ -> atom_to_binary(Reason);
        Text -> unicode:characters_to_binary(Text)
    end;
describe(Reason) -> unicode:characters_to_binary(io_lib:format("~0p", [Reason])).

%% Round robin over a pool's connections.
counter_new() -> counters:new(1, [write_concurrency]).

counter_next(Counter, Size) ->
    counters:add(Counter, 1, 1),
    counters:get(Counter, 1) rem Size.

pick(Tuple, Index) -> element(Index + 1, Tuple).

tuple_from_list(List) -> list_to_tuple(List).

%% A named pool's connections, so handles made with from_name find the
%% current ones across restarts.
pool_put(Name, Pool) -> persistent_term:put({gloss_redis, Name}, Pool), nil.

pool_get(Name) ->
    try {ok, persistent_term:get({gloss_redis, Name})}
    catch error:badarg -> {error, nil}
    end.

%% Sending to a subject whose process is gone, or to a name that isn't
%% registered, is not a crash.
try_send(Subject, Message) ->
    try 'gleam@erlang@process':send(Subject, Message), true
    catch _:_ -> false
    end.

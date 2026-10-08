-module('gloss@internal@socket_ffi').
-export([connect/3, upgrade/4, send/2, recv/3, alive/1, transfer/2, close/1,
         activate_once/1, activate/1, deactivate/1, event/2]).

%% A client socket is {tcp, Port} or {ssl, SslSocket}, so callers needn't
%% care which. Sockets start passive and raw: the protocol does the framing.

connect(Host, Port, Timeout) ->
    Options = [binary, {active, false}, {packet, raw}, {nodelay, true},
               {keepalive, true}],
    case gen_tcp:connect(binary_to_list(Host), Port, Options, Timeout) of
        {ok, Socket} -> {ok, {tcp, Socket}};
        {error, Reason} -> {error, describe(Reason)}
    end.

%% Start TLS on a connected socket. With Verify the server's certificate
%% must chain to a system CA and match Host.
upgrade({tcp, Socket}, Host, Verify, Timeout) ->
    {ok, _} = application:ensure_all_started(ssl),
    Name = binary_to_list(Host),
    Options = case Verify of
        true ->
            [{verify, verify_peer},
             {cacerts, public_key:cacerts_get()},
             {server_name_indication, Name},
             {customize_hostname_check,
              [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}];
        false ->
            [{verify, verify_none}]
    end,
    case ssl:connect(Socket, Options, Timeout) of
        {ok, Tls} -> {ok, {ssl, Tls}};
        {error, Reason} -> {error, describe(Reason)}
    end.

send({tcp, Socket}, Data) -> sent(gen_tcp:send(Socket, Data));
send({ssl, Socket}, Data) -> sent(ssl:send(Socket, Data)).

sent(ok) -> {ok, nil};
sent({error, Reason}) -> {error, describe(Reason)}.

%% Length bytes, or whatever is available when Length is 0, waiting up to
%% Timeout milliseconds.
recv({tcp, Socket}, Length, Timeout) -> received(gen_tcp:recv(Socket, Length, Timeout));
recv({ssl, Socket}, Length, Timeout) -> received(ssl:recv(Socket, Length, Timeout)).

received({ok, Data}) -> {ok, Data};
received({error, timeout}) -> {error, timeout};
received({error, closed}) -> {error, closed};
received({error, Reason}) -> {error, {failed, describe(Reason)}}.

%% An idle connection has nothing to read. Data, an error or a closed
%% socket all mean it can't be trusted.
alive(Socket) ->
    case recv(Socket, 0, 0) of
        {error, timeout} -> true;
        _ -> false
    end.

transfer({tcp, Socket}, Pid) -> _ = gen_tcp:controlling_process(Socket, Pid), nil;
transfer({ssl, Socket}, Pid) -> _ = ssl:controlling_process(Socket, Pid), nil.

close({tcp, Socket}) -> _ = gen_tcp:close(Socket), nil;
close({ssl, Socket}) -> _ = ssl:close(Socket), nil.

%% Deliver the next bytes as a message to the owner.
activate_once({tcp, Socket}) -> _ = inet:setopts(Socket, [{active, once}]), nil;
activate_once({ssl, Socket}) -> _ = ssl:setopts(Socket, [{active, once}]), nil.

%% Deliver everything that arrives as messages to the owner.
activate({tcp, Socket}) -> _ = inet:setopts(Socket, [{active, true}]), nil;
activate({ssl, Socket}) -> _ = ssl:setopts(Socket, [{active, true}]), nil.

%% Back to passive mode, returning bytes already delivered as messages.
deactivate({tcp, Socket} = S) ->
    _ = inet:setopts(Socket, [{active, false}]), flush(S, <<>>);
deactivate({ssl, Socket} = S) ->
    _ = ssl:setopts(Socket, [{active, false}]), flush(S, <<>>).

flush({Kind, Socket} = S, Acc) ->
    receive
        {Kind, Socket, Data} -> flush(S, <<Acc/binary, Data/binary>>)
    after 0 -> Acc
    end.

%% What a message the owner received means for Socket.
event({tcp, S}, {tcp, S, Data}) -> {data, Data};
event({ssl, S}, {ssl, S, Data}) -> {data, Data};
event({tcp, S}, {tcp_closed, S}) -> {disconnected, <<"closed">>};
event({ssl, S}, {ssl_closed, S}) -> {disconnected, <<"closed">>};
event({tcp, S}, {tcp_error, S, R}) -> {disconnected, describe(R)};
event({ssl, S}, {ssl_error, S, R}) -> {disconnected, describe(R)};
event(_, _) -> not_socket.

describe(Reason) when is_atom(Reason) ->
    case inet:format_error(Reason) of
        "unknown POSIX error" ++ _ -> atom_to_binary(Reason);
        Text -> unicode:characters_to_binary(Text)
    end;
describe(Reason) -> unicode:characters_to_binary(io_lib:format("~0p", [Reason])).

-module(gloss@pg_ffi).
-export([connect/3, upgrade/4, send/2, recv/2, alive/1, transfer/2, close/1,
         pbkdf2/3]).

%% A socket is {tcp, Port} or {ssl, SslSocket}, so callers needn't care
%% which. Sockets are passive and raw: the protocol code does the framing.

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

%% Whatever bytes are available, waiting up to Timeout milliseconds.
recv({tcp, Socket}, Timeout) -> received(gen_tcp:recv(Socket, 0, Timeout));
recv({ssl, Socket}, Timeout) -> received(ssl:recv(Socket, 0, Timeout)).

received({ok, Data}) -> {ok, Data};
received({error, timeout}) -> {error, timeout};
received({error, closed}) -> {error, closed};
received({error, Reason}) -> {error, {failed, describe(Reason)}}.

%% An idle connection has nothing to read. Data, an error or a closed
%% socket all mean it can't be trusted with a statement.
alive(Socket) ->
    case recv(Socket, 0) of
        {error, timeout} -> true;
        _ -> false
    end.

transfer({tcp, Socket}, Pid) -> _ = gen_tcp:controlling_process(Socket, Pid), nil;
transfer({ssl, Socket}, Pid) -> _ = ssl:controlling_process(Socket, Pid), nil.

close({tcp, Socket}) -> _ = gen_tcp:close(Socket), nil;
close({ssl, Socket}) -> _ = ssl:close(Socket), nil.

%% gleam_crypto has no key derivation, so PBKDF2 comes from OTP directly.
pbkdf2(Password, Salt, Iterations) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, 32).

describe(Reason) when is_atom(Reason) ->
    case inet:format_error(Reason) of
        "unknown POSIX error" -> atom_to_binary(Reason);
        Message -> unicode:characters_to_binary(Message)
    end;
describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

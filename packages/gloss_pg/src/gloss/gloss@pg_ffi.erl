-module(gloss@pg_ffi).
-export([connect/3, upgrade/4, send/2, recv/2, alive/1, transfer/2, close/1,
         pbkdf2/3, pg_connection/1, coerce/1, activate/1, deactivate/1, socket_message/2,
         cache_new/1, cache_lookup/2, cache_next_name/1, cache_put/4,
         cache_delete/2, cache_take_closing/1, cache_give/2, cache_drop/1]).

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

coerce(Value) -> Value.

%% The driver's connection record, from sql.Connection's raw field.
pg_connection({pg_connection, _, _} = Connection) -> {ok, Connection};
pg_connection(_) -> {error, nil}.

%% --- Active mode, for a listener --------------------------------------------

%% Deliver the next bytes as a message to the owner.
activate({tcp, Socket}) -> _ = inet:setopts(Socket, [{active, once}]), nil;
activate({ssl, Socket}) -> _ = ssl:setopts(Socket, [{active, once}]), nil.

%% Back to passive mode, returning bytes already delivered as a message.
deactivate({tcp, Socket} = S) ->
    _ = inet:setopts(Socket, [{active, false}]), flush(S, <<>>);
deactivate({ssl, Socket} = S) ->
    _ = ssl:setopts(Socket, [{active, false}]), flush(S, <<>>).

flush({Kind, Socket} = S, Acc) ->
    receive
        {Kind, Socket, Data} -> flush(S, <<Acc/binary, Data/binary>>)
    after 0 -> Acc
    end.

%% Classify a message the owner received, as a pg_connection RawSocketMessage.
socket_message({tcp, Socket}, {tcp, Socket, Data}) -> {raw_data, Data};
socket_message({ssl, Socket}, {ssl, Socket, Data}) -> {raw_data, Data};
socket_message({tcp, Socket}, {tcp_closed, Socket}) -> raw_closed;
socket_message({tcp, Socket}, {tcp_error, Socket, _}) -> raw_closed;
socket_message({ssl, Socket}, {ssl_closed, Socket}) -> raw_closed;
socket_message({ssl, Socket}, {ssl_error, Socket, _}) -> raw_closed;
socket_message(_, _) -> raw_other.

%% --- Prepared statement cache ---------------------------------------------
%%
%% One public ETS table per connection, so whichever process has borrowed
%% the connection can use it. Rows are {{sql, Sql}, Name, Types, LastUsed};
%% '$tick' numbers statement names and uses, and '$closing' holds names of
%% evicted statements to close on the server with the next request.

cache_new(Max) ->
    Table = ets:new(gloss_pg_statements, [set, public]),
    ets:insert(Table, [{'$max', Max}, {'$tick', 0}, {'$closing', []}]),
    Table.

cache_lookup(Table, Sql) ->
    case ets:lookup(Table, {sql, Sql}) of
        [{Key, Name, Types, _}] ->
            ets:update_element(Table, Key, {4, tick(Table)}),
            {ok, {Name, Types}};
        [] -> {error, nil}
    end.

cache_next_name(Table) ->
    <<"gloss_", (integer_to_binary(tick(Table)))/binary>>.

cache_put(Table, Sql, Name, Types) ->
    ets:insert(Table, {{sql, Sql}, Name, Types, tick(Table)}),
    [{_, Max}] = ets:lookup(Table, '$max'),
    case ets:info(Table, size) - 3 > Max of
        true -> evict_oldest(Table);
        false -> ok
    end,
    nil.

cache_delete(Table, Sql) ->
    case ets:lookup(Table, {sql, Sql}) of
        [{Key, Name, _, _}] -> ets:delete(Table, Key), closing(Table, Name);
        [] -> ok
    end,
    nil.

cache_take_closing(Table) ->
    [{_, Names}] = ets:lookup(Table, '$closing'),
    ets:insert(Table, {'$closing', []}),
    Names.

cache_give(Table, Pid) -> _ = ets:give_away(Table, Pid, gloss_pg_statements), nil.

cache_drop(Table) -> catch ets:delete(Table), nil.

tick(Table) -> ets:update_counter(Table, '$tick', 1).

closing(Table, Name) ->
    [{_, Names}] = ets:lookup(Table, '$closing'),
    ets:insert(Table, {'$closing', [Name | Names]}).

evict_oldest(Table) ->
    Oldest = ets:foldl(
        fun({{sql, _} = Key, Name, _, Used}, none) -> {Key, Name, Used};
           ({{sql, _} = Key, Name, _, Used}, {_, _, Best}) when Used < Best ->
                {Key, Name, Used};
           (_, Best) -> Best
        end, none, Table),
    case Oldest of
        {Key, Name, _} -> ets:delete(Table, Key), closing(Table, Name);
        none -> ok
    end.

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

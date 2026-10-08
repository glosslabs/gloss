-module(gloss@mysql_ffi).
-export([connect/3, upgrade/4, send/2, recv/3, alive/1, transfer/2, close/1,
         coerce/1, mysql_connection/1, rsa_encrypt/2,
         cache_new/1, cache_lookup/2, cache_put/3, cache_delete/2,
         cache_take_closing/1, cache_give/2, cache_drop/1]).

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

%% Length bytes, or whatever is available when Length is 0, waiting up to
%% Timeout milliseconds.
recv({tcp, Socket}, Length, Timeout) -> received(gen_tcp:recv(Socket, Length, Timeout));
recv({ssl, Socket}, Length, Timeout) -> received(ssl:recv(Socket, Length, Timeout)).

received({ok, Data}) -> {ok, Data};
received({error, timeout}) -> {error, timeout};
received({error, closed}) -> {error, closed};
received({error, Reason}) -> {error, {failed, describe(Reason)}}.

%% An idle connection has nothing to read. Data, an error or a closed
%% socket all mean it can't be trusted with a statement.
alive(Socket) ->
    case recv(Socket, 0, 0) of
        {error, timeout} -> true;
        _ -> false
    end.

transfer({tcp, Socket}, Pid) -> _ = gen_tcp:controlling_process(Socket, Pid), nil;
transfer({ssl, Socket}, Pid) -> _ = ssl:controlling_process(Socket, Pid), nil.

close({tcp, Socket}) -> _ = gen_tcp:close(Socket), nil;
close({ssl, Socket}) -> _ = ssl:close(Socket), nil.

coerce(Value) -> Value.

%% The driver's connection record, from pool.Connection's raw field.
mysql_connection({my_connection, _, _, _} = Connection) -> {ok, Connection};
mysql_connection(_) -> {error, nil}.

%% Encrypt Data with the server's RSA public key (PEM), OAEP padded, as
%% caching_sha2_password asks for over a connection without TLS.
rsa_encrypt(Pem, Data) ->
    try
        [Entry | _] = public_key:pem_decode(Pem),
        Key = public_key:pem_entry_decode(Entry),
        {ok, public_key:encrypt_public(Data, Key,
                                       [{rsa_padding, rsa_pkcs1_oaep_padding}])}
    catch
        _:_ -> {error, nil}
    end.

%% --- Prepared statement cache ---------------------------------------------
%%
%% One public ETS table per connection, so whichever process has borrowed
%% the connection can use it. Rows are {{sql, Sql}, Statement, LastUsed};
%% '$tick' counts uses, and '$closing' holds evicted statements to close on
%% the server before the next command.

cache_new(Max) ->
    Table = ets:new(gloss_mysql_statements, [set, public]),
    ets:insert(Table, [{'$max', Max}, {'$tick', 0}, {'$closing', []}]),
    Table.

cache_lookup(Table, Sql) ->
    case ets:lookup(Table, {sql, Sql}) of
        [{Key, Statement, _}] ->
            ets:update_element(Table, Key, {3, tick(Table)}),
            {ok, Statement};
        [] -> {error, nil}
    end.

cache_put(Table, Sql, Statement) ->
    ets:insert(Table, {{sql, Sql}, Statement, tick(Table)}),
    [{_, Max}] = ets:lookup(Table, '$max'),
    case ets:info(Table, size) - 3 > Max of
        true -> evict_oldest(Table);
        false -> ok
    end,
    nil.

cache_delete(Table, Sql) ->
    case ets:lookup(Table, {sql, Sql}) of
        [{Key, Statement, _}] -> ets:delete(Table, Key), closing(Table, Statement);
        [] -> ok
    end,
    nil.

cache_take_closing(Table) ->
    [{_, Statements}] = ets:lookup(Table, '$closing'),
    ets:insert(Table, {'$closing', []}),
    Statements.

cache_give(Table, Pid) -> _ = ets:give_away(Table, Pid, gloss_mysql_statements), nil.

cache_drop(Table) -> catch ets:delete(Table), nil.

tick(Table) -> ets:update_counter(Table, '$tick', 1).

closing(Table, Statement) ->
    [{_, Statements}] = ets:lookup(Table, '$closing'),
    ets:insert(Table, {'$closing', [Statement | Statements]}).

evict_oldest(Table) ->
    Oldest = ets:foldl(
        fun({{sql, _} = Key, Statement, Used}, none) -> {Key, Statement, Used};
           ({{sql, _} = Key, Statement, Used}, {_, _, Best}) when Used < Best ->
                {Key, Statement, Used};
           (_, Best) -> Best
        end, none, Table),
    case Oldest of
        {Key, Statement, _} -> ets:delete(Table, Key), closing(Table, Statement);
        none -> ok
    end.

describe(Reason) when is_atom(Reason) ->
    case inet:format_error(Reason) of
        "unknown POSIX error" -> atom_to_binary(Reason);
        Message -> unicode:characters_to_binary(Message)
    end;
describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

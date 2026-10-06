-module(http_client_ffi).
-export([connect/1, send/2, read_response/2, read_head/2, is_closed/2, close/1]).

%% A minimal HTTP/1.1 client over a raw socket, for exercising the server's
%% connection handling.

connect(Port) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000) of
        {ok, Socket} -> {ok, Socket};
        {error, _} -> {error, nil}
    end.

send(Socket, Data) ->
    ok = gen_tcp:send(Socket, Data),
    nil.

close(Socket) ->
    gen_tcp:close(Socket),
    nil.

%% A response to HEAD: status and headers, no body.
read_head(Socket, Timeout) ->
    ok = inet:setopts(Socket, [{packet, http_bin}]),
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, {http_response, _, Status, _}} ->
            Headers = read_headers(Socket, Timeout, []),
            ok = inet:setopts(Socket, [{packet, raw}]),
            {ok, {Status, Headers, <<>>}};
        {error, _} ->
            {error, nil}
    end.

%% {ok, {Status, Headers, Body}} where header names are lowercase.
read_response(Socket, Timeout) ->
    ok = inet:setopts(Socket, [{packet, http_bin}]),
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, {http_response, _, Status, _}} ->
            Headers = read_headers(Socket, Timeout, []),
            ok = inet:setopts(Socket, [{packet, raw}]),
            Length = binary_to_integer(proplists:get_value(<<"content-length">>, Headers, <<"0">>)),
            Body = case Length of
                0 -> <<>>;
                _ -> {ok, B} = gen_tcp:recv(Socket, Length, Timeout), B
            end,
            {ok, {Status, Headers, Body}};
        {error, _} ->
            ok = inet:setopts(Socket, [{packet, raw}]),
            {error, nil}
    end.

read_headers(Socket, Timeout, Acc) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, {http_header, _, Name, _, Value}} ->
            Key = string:lowercase(if is_atom(Name) -> atom_to_binary(Name); true -> Name end),
            read_headers(Socket, Timeout, [{Key, Value} | Acc]);
        {ok, http_eoh} ->
            lists:reverse(Acc)
    end.

%% Whether the server has closed the connection.
is_closed(Socket, Timeout) ->
    ok = inet:setopts(Socket, [{packet, raw}]),
    case gen_tcp:recv(Socket, 0, Timeout) of
        {error, closed} -> true;
        _ -> false
    end.

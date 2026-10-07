-module(http_client_ffi).
-export([connect/1, recv_until/3, connect_unix/1, make_file/1, stale_socket/1, exists/1, send/2, read_response/2, read_head/2, is_closed/2, close/1]).

%% A minimal HTTP/1.1 client over a raw socket, for exercising the server's
%% connection handling.

connect(Port) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000) of
        {ok, Socket} -> {ok, Socket};
        {error, _} -> {error, nil}
    end.

connect_unix(Path) ->
    case gen_tcp:connect({local, Path}, 0, [local, binary, {active, false}], 1000) of
        {ok, Socket} -> {ok, Socket};
        {error, _} -> {error, nil}
    end.

make_file(Path) ->
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"not a socket">>),
    nil.

%% Leave a socket file with nothing listening, as a crash would.
stale_socket(Path) ->
    {ok, S} = gen_tcp:listen(0, [local, {ifaddr, {local, Path}}]),
    ok = gen_tcp:close(S),
    nil.

exists(Path) -> element(1, file:read_link_info(Path)) =:= ok.

%% Read raw bytes until Needle has arrived: {ok, AllRead} or {error, nil}.
recv_until(Socket, Needle, Timeout) -> recv_until(Socket, Needle, Timeout, <<>>).
recv_until(Socket, Needle, Timeout, Acc) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, Data} -> recv_until(Socket, Needle, Timeout, <<Acc/binary, Data/binary>>);
                {error, _} -> {error, nil}
            end;
        _ -> {ok, Acc}
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
            Body = case proplists:get_value(<<"transfer-encoding">>, Headers) of
                <<"chunked">> -> read_chunks(Socket, Timeout, <<>>);
                _ ->
                    case proplists:get_value(<<"content-length">>, Headers) of
                        undefined -> read_until_closed(Socket, Timeout, <<>>);
                        Value ->
                            case binary_to_integer(Value) of
                                0 -> <<>>;
                                Length ->
                                    {ok, B} = gen_tcp:recv(Socket, Length, Timeout),
                                    B
                            end
                    end
            end,
            {ok, {Status, Headers, Body}};
        {error, _} ->
            ok = inet:setopts(Socket, [{packet, raw}]),
            {error, nil}
    end.

read_chunks(Socket, Timeout, Acc) ->
    ok = inet:setopts(Socket, [{packet, line}]),
    {ok, Line} = gen_tcp:recv(Socket, 0, Timeout),
    Hex = binary:part(Line, 0, byte_size(Line) - 2),
    Size = binary_to_integer(Hex, 16),
    ok = inet:setopts(Socket, [{packet, raw}]),
    case Size of
        0 ->
            {ok, <<"\r\n">>} = gen_tcp:recv(Socket, 2, Timeout),
            Acc;
        _ ->
            {ok, Data} = gen_tcp:recv(Socket, Size, Timeout),
            {ok, <<"\r\n">>} = gen_tcp:recv(Socket, 2, Timeout),
            read_chunks(Socket, Timeout, <<Acc/binary, Data/binary>>)
    end.

read_until_closed(Socket, Timeout, Acc) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} -> read_until_closed(Socket, Timeout, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
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

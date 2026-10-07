-module(gloss@testing@websocket_ffi).
-export([connect/4, send_frame/4, recv_frame/2, close/1, closed/2]).

%% The socket side of gloss/testing/websocket: the opening handshake, masked
%% client frames, and reading server frames.

connect(Port, Path, Headers, Timeout) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], Timeout) of
        {error, Reason} -> {error, {unreachable, describe(Reason)}};
        {ok, S} ->
            Key = base64:encode(crypto:strong_rand_bytes(16)),
            Extra = [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- Headers],
            ok = gen_tcp:send(S, [<<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
                <<"host: localhost:">>, integer_to_binary(Port), <<"\r\n">>,
                <<"upgrade: websocket\r\nconnection: Upgrade\r\n">>,
                <<"sec-websocket-key: ">>, Key, <<"\r\n">>,
                <<"sec-websocket-version: 13\r\n">>, Extra, <<"\r\n">>]),
            ok = inet:setopts(S, [{packet, http_bin}]),
            case gen_tcp:recv(S, 0, Timeout) of
                {ok, {http_response, _, Status, _}} ->
                    Received = headers(S, Timeout, []),
                    ok = inet:setopts(S, [{packet, raw}]),
                    {ok, {S, Status, Received}};
                {error, Reason} ->
                    gen_tcp:close(S),
                    {error, {unreachable, describe(Reason)}}
            end
    end.

headers(S, Timeout, Acc) ->
    case gen_tcp:recv(S, 0, Timeout) of
        {ok, {http_header, _, Name, _, Value}} ->
            Key = string:lowercase(if is_atom(Name) -> atom_to_binary(Name); true -> Name end),
            headers(S, Timeout, [{Key, Value} | Acc]);
        _ -> lists:reverse(Acc)
    end.

%% One masked frame, as a client must send it.
send_frame(S, Fin, Opcode, Payload) ->
    Key = crypto:strong_rand_bytes(4),
    Size = byte_size(Payload),
    Len = if Size < 126 -> <<1:1, Size:7>>;
             Size < 65536 -> <<1:1, 126:7, Size:16>>;
             true -> <<1:1, 127:7, Size:64>>
          end,
    FinBit = case Fin of true -> 1; false -> 0 end,
    Frame = <<FinBit:1, 0:3, Opcode:4, Len/bits, Key/binary, (mask(Key, Payload))/binary>>,
    case gen_tcp:send(S, Frame) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

mask(Key, Payload) ->
    Size = byte_size(Payload),
    Keys = binary:copy(Key, (Size div 4) + 1),
    <<K:Size/binary, _/binary>> = Keys,
    crypto:exor(Payload, K).

%% One server frame: {ok, {Fin, Opcode, Payload}}, or {error, timeout | closed}.
recv_frame(S, Timeout) ->
    case gen_tcp:recv(S, 2, Timeout) of
        {ok, <<Fin:1, _:3, Opcode:4, _Masked:1, Len:7>>} ->
            Size = case Len of
                126 -> {ok, <<N:16>>} = gen_tcp:recv(S, 2, Timeout), N;
                127 -> {ok, <<N:64>>} = gen_tcp:recv(S, 8, Timeout), N;
                N -> N
            end,
            case Size of
                0 -> {ok, {Fin =:= 1, Opcode, <<>>}};
                _ ->
                    case gen_tcp:recv(S, Size, Timeout) of
                        {ok, Payload} -> {ok, {Fin =:= 1, Opcode, Payload}};
                        {error, timeout} -> {error, timeout};
                        {error, _} -> {error, closed}
                    end
            end;
        {error, timeout} -> {error, timeout};
        {error, _} -> {error, closed}
    end.

close(S) ->
    _ = gen_tcp:close(S),
    nil.

%% Whether the server closes the connection within Timeout milliseconds.
closed(S, Timeout) ->
    case gen_tcp:recv(S, 0, Timeout) of
        {error, closed} -> true;
        {ok, _} -> closed(S, Timeout);
        _ -> false
    end.

describe(Reason) -> iolist_to_binary(io_lib:format("~0p", [Reason])).

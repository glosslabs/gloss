-module(ws_client_ffi).
-export([connect/2, connect_with/3, send/4, send_compressed/3, recv/2,
         recv_compressed/2, closed/2, close/1]).

%% A minimal WebSocket client for tests: connects, upgrades, and exchanges
%% masked frames.

connect(Port, Path) ->
    {ok, {S, Status, Headers}} = connect_with(Port, Path, []),
    {ok, {S, Status, proplists:get_value(<<"sec-websocket-accept">>, Headers, <<>>)}}.

%% Connect sending extra request headers; answers the response headers.
connect_with(Port, Path, Extra) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(S, [<<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
        <<"host: localhost\r\nupgrade: websocket\r\nconnection: Upgrade\r\n">>,
        <<"sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n">>,
        [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Extra],
        <<"sec-websocket-version: 13\r\n\r\n">>]),
    ok = inet:setopts(S, [{packet, http_bin}]),
    {ok, {http_response, _, Status, _}} = gen_tcp:recv(S, 0, 1000),
    Headers = headers(S, []),
    ok = inet:setopts(S, [{packet, raw}]),
    {ok, {S, Status, Headers}}.

headers(S, Acc) ->
    case gen_tcp:recv(S, 0, 1000) of
        {ok, {http_header, _, Name, _, Value}} ->
            Key = string:lowercase(if is_atom(Name) -> atom_to_binary(Name); true -> Name end),
            headers(S, [{Key, Value} | Acc]);
        {ok, http_eoh} -> Acc
    end.

%% Send one masked frame.
send(S, Opcode, Payload, Fin) ->
    Key = <<1, 2, 3, 4>>,
    Size = byte_size(Payload),
    Len = if Size < 126 -> <<1:1, Size:7>>;
             Size < 65536 -> <<1:1, 126:7, Size:16>>;
             true -> <<1:1, 127:7, Size:64>>
          end,
    Masked = 'gloss@http@server_ffi':unmask(Key, Payload),
    FinBit = case Fin of true -> 1; false -> 0 end,
    ok = gen_tcp:send(S, <<FinBit:1, 0:3, Opcode:4, Len/bits, Key/binary, Masked/binary>>),
    nil.

%% Send one message compressed with permessage-deflate (RSV1 set).
send_compressed(S, Opcode, Payload) ->
    Z = zlib:open(),
    ok = zlib:deflateInit(Z, default, deflated, -15, 8, default),
    Out = iolist_to_binary(zlib:deflate(Z, Payload, sync)),
    zlib:close(Z),
    Body = binary:part(Out, 0, byte_size(Out) - 4),
    Key = <<1, 2, 3, 4>>,
    Size = byte_size(Body),
    Len = if Size < 126 -> <<1:1, Size:7>>;
             Size < 65536 -> <<1:1, 126:7, Size:16>>;
             true -> <<1:1, 127:7, Size:64>>
          end,
    Masked = 'gloss@http@server_ffi':unmask(Key, Body),
    ok = gen_tcp:send(S, <<1:1, 4:3, Opcode:4, Len/bits, Key/binary, Masked/binary>>),
    nil.

%% Receive one frame, inflating it when RSV1 is set:
%% {ok, {Compressed, Opcode, Payload}}.
recv_compressed(S, Timeout) ->
    case gen_tcp:recv(S, 2, Timeout) of
        {ok, <<_:1, Rsv1:1, _:2, Opcode:4, 0:1, Len:7>>} ->
            Size = case Len of
                126 -> {ok, <<N:16>>} = gen_tcp:recv(S, 2, Timeout), N;
                127 -> {ok, <<N:64>>} = gen_tcp:recv(S, 8, Timeout), N;
                N -> N
            end,
            Payload = case Size of
                0 -> <<>>;
                _ -> {ok, P} = gen_tcp:recv(S, Size, Timeout), P
            end,
            case Rsv1 of
                1 ->
                    Z = zlib:open(),
                    ok = zlib:inflateInit(Z, -15),
                    Out = iolist_to_binary(zlib:inflate(Z, [Payload, <<0, 0, 255, 255>>])),
                    zlib:close(Z),
                    {ok, {true, Opcode, Out}};
                0 -> {ok, {false, Opcode, Payload}}
            end;
        _ -> {error, nil}
    end.

%% Receive one unmasked server frame: {ok, {Opcode, Payload}}.
recv(S, Timeout) ->
    case gen_tcp:recv(S, 2, Timeout) of
        {ok, <<_:4, Opcode:4, 0:1, Len:7>>} ->
            Size = case Len of
                126 -> {ok, <<N:16>>} = gen_tcp:recv(S, 2, Timeout), N;
                127 -> {ok, <<N:64>>} = gen_tcp:recv(S, 8, Timeout), N;
                N -> N
            end,
            Payload = case Size of
                0 -> <<>>;
                _ -> {ok, P} = gen_tcp:recv(S, Size, Timeout), P
            end,
            {ok, {Opcode, Payload}};
        _ -> {error, nil}
    end.

closed(S, Timeout) ->
    case gen_tcp:recv(S, 0, Timeout) of
        {error, closed} -> true;
        _ -> false
    end.

close(S) ->
    _ = gen_tcp:close(S),
    nil.

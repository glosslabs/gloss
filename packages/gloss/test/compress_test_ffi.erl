-module(compress_test_ffi).
-export([gunzip/1, first_chunk_text/2]).

gunzip(Data) ->
    try {ok, zlib:gunzip(Data)} catch _:_ -> {error, nil} end.

%% Connect, ask for a gzipped stream, and inflate only its first chunk.
first_chunk_text(Port, Path) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(S, [<<"GET ">>, Path, <<" HTTP/1.1\r\naccept-encoding: gzip\r\n\r\n">>]),
    ok = inet:setopts(S, [{packet, http_bin}]),
    {ok, {http_response, _, 200, _}} = gen_tcp:recv(S, 0, 1000),
    skip_headers(S),
    ok = inet:setopts(S, [{packet, line}]),
    {ok, SizeLine} = gen_tcp:recv(S, 0, 1000),
    Size = binary_to_integer(binary:part(SizeLine, 0, byte_size(SizeLine) - 2), 16),
    ok = inet:setopts(S, [{packet, raw}]),
    {ok, Chunk} = gen_tcp:recv(S, Size, 1000),
    Z = zlib:open(),
    ok = zlib:inflateInit(Z, 31),
    Text = iolist_to_binary(zlib:inflate(Z, Chunk)),
    gen_tcp:close(S),
    Text.

skip_headers(S) ->
    case gen_tcp:recv(S, 0, 1000) of
        {ok, http_eoh} -> ok;
        {ok, _} -> skip_headers(S)
    end.

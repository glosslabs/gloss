-module(gloss@http@server_ffi).

-export([listen_unix/2, close_listener/1, listen/3, port/1, accept/1, controlling_process/2, close/1, send/2,
         sendfile/4, read_range/3, file_info/1, priv_dir/1, read_line/2,
         unmask/2, arm_raw/1, is_drain/1, http_date/1, pdict_get/1,
         gzip/1, gzip_open/0, gzip_chunk/2, gzip_finish/1,
         inflate_open/0, inflate/2, inflate_continue/1, inflate_end/1,
         peer_address/1, ip_bytes/1, find/2,
         upload_open/1, upload_write/2, upload_close/1, upload_rename/2,
         upload_delete/1,
         next/2, next_header/2, read_body/3, drain_requested/0, request_drain/1, await_go/0,
         go/1, rescue/1, http_date/0,
         new_flag/0, raise_flag/1, flag_raised/1,
         stash/1, unstash/1, drop_stash/1]).

%% --- Sockets ----------------------------------------------------------------

%% Listen in `http_bin` packet mode, passive. Accepted sockets inherit the
%% options. `packet_size` bounds the request line and each header line.
%% `exit_on_close` is off so the socket can still answer 414 or 431 after a
%% line exceeds it; connections always close their sockets themselves.
listen(Interface, Port, Backlog) ->
    case inet:parse_address(binary_to_list(Interface)) of
        {error, _} ->
            {error, invalid_interface};
        {ok, Address} ->
            Family = case tuple_size(Address) of 4 -> inet; 8 -> inet6 end,
            Options = [binary, Family, {ip, Address}, {packet, http_bin},
                       {packet_size, 16384}, {active, false},
                       {reuseaddr, true}, {nodelay, true},
                       {backlog, Backlog}, {send_timeout, 30000},
                       {send_timeout_close, true},
                       {exit_on_close, false}],
            case gen_tcp:listen(Port, Options) of
                {ok, Socket} -> {ok, Socket};
                {error, eaddrinuse} -> {error, address_in_use};
                {error, Reason} -> {error, {other, describe(Reason)}}
            end
    end.

%% Listen on a Unix domain socket at Path. A socket file left by a server
%% that crashed is removed first, but only when it is a socket and nothing
%% answers on it.
listen_unix(Path, Backlog) ->
    case clear_stale(Path) of
        {error, _} = Error -> Error;
        ok ->
            Options = [binary, local, {ifaddr, {local, Path}},
                       {packet, http_bin}, {packet_size, 16384},
                       {active, false}, {backlog, Backlog},
                       {send_timeout, 30000}, {send_timeout_close, true},
                       {exit_on_close, false}],
            case gen_tcp:listen(0, Options) of
                {ok, Socket} -> {ok, Socket};
                {error, eaddrinuse} -> {error, address_in_use};
                {error, Reason} -> {error, {other, describe(Reason)}}
            end
    end.

clear_stale(Path) ->
    case file:read_link_info(Path) of
        {error, enoent} -> ok;
        {ok, Info} when element(3, Info) =:= other ->
            case gen_tcp:connect({local, Path}, 0, [local], 1000) of
                {ok, S} -> gen_tcp:close(S), {error, address_in_use};
                {error, _} -> _ = file:delete(Path), ok
            end;
        {ok, _} -> {error, {other, <<"the path exists and is not a socket">>}};
        {error, Reason} -> {error, {other, describe(Reason)}}
    end.

%% Close a listen socket, removing a Unix socket's file.
close_listener(Socket) ->
    Name = inet:sockname(Socket),
    _ = gen_tcp:close(Socket),
    case Name of
        {ok, {local, Path}} -> _ = file:delete(Path), nil;
        _ -> nil
    end.

%% The port of a TCP listen socket; 0 for a Unix socket.
port(Socket) ->
    case inet:port(Socket) of
        {ok, Port} when is_integer(Port) -> Port;
        _ -> 0
    end.

accept(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} -> {ok, Socket};
        {error, closed} -> {error, closed};
        {error, Reason} -> {error, {failed, describe(Reason)}}
    end.

controlling_process(Socket, Pid) ->
    _ = gen_tcp:controlling_process(Socket, Pid),
    nil.

close(Socket) ->
    _ = gen_tcp:close(Socket),
    nil.

send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

%% sendfile/5 takes an open raw file, not a file name.
sendfile(Socket, Path, Offset, Length) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, File} ->
            Result = file:sendfile(File, Socket, Offset, Length, []),
            _ = file:close(File),
            case Result of
                {ok, Length} -> {ok, nil};
                _ -> {error, nil}
            end;
        {error, _} -> {error, nil}
    end.

%% Read part of a file into memory, for server.handle in tests.
read_range(Path, Offset, Length) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Device} ->
            Result = file:pread(Device, Offset, Length),
            _ = file:close(Device),
            case Result of
                {ok, Data} -> {ok, Data};
                eof -> {ok, <<>>};
                {error, _} -> {error, nil}
            end;
        {error, _} -> {error, nil}
    end.

%% {ok, {Size, MtimeSeconds}} for a regular file; {error, nil} for
%% anything else, including directories and missing paths.
file_info(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, Info} when element(3, Info) =:= regular ->
            {ok, {element(2, Info), element(6, Info)}};
        _ -> {error, nil}
    end.

priv_dir(Name) ->
    try code:priv_dir(binary_to_existing_atom(Name)) of
        {error, _} -> {error, nil};
        Dir -> {ok, unicode:characters_to_binary(Dir)}
    catch
        error:badarg -> {error, nil}
    end.

%% Wait for the next request-line or header packet, a drain request, or the
%% timeout, whichever comes first. The socket is armed for one packet.
next(Socket, Timeout) ->
    _ = inet:setopts(Socket, [{active, once}]),
    receive
        {http, Socket, Packet} ->
            packet(Packet);
        {tcp_error, Socket, emsgsize} ->
            line_too_long;
        {tcp_closed, Socket} ->
            connection_closed;
        {tcp_error, Socket, _} ->
            connection_closed;
        gloss_http_drain ->
            drain
    after Timeout ->
        timeout
    end.

%% The next packet once a request has started, read without arming the
%% socket. A drain request waits in the mailbox for drain_requested/0.
next_header(Socket, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Packet} -> packet(Packet);
        {error, timeout} -> timeout;
        {error, emsgsize} -> line_too_long;
        {error, _} -> connection_closed
    end.

packet({http_request, Method, Uri, Version}) ->
    {request_line, to_binary(Method), target(Uri), Version};
packet({http_header, _, Name, _, Value}) ->
    {header, header_name(Name), Value};
packet(http_eoh) ->
    end_of_headers;
packet({http_error, Line}) ->
    {bad_request, to_binary(Line)}.

%% Lowercase. Known names arrive as atoms in canonical case, e.g.
%% 'Content-Length'; others as binaries. Names are ASCII tokens.
header_name(Name) when is_atom(Name) ->
    ascii_lowercase(atom_to_binary(Name));
header_name(Name) ->
    ascii_lowercase(Name).

ascii_lowercase(Bin) ->
    << <<(case C of _ when C >= $A, C =< $Z -> C + 32; _ -> C end)>>
       || <<C>> <= Bin >>.

%% Read exactly `Length` body bytes, then return to header parsing for the
%% next request on the connection.
read_body(_Socket, 0, _Timeout) ->
    {ok, <<>>};
read_body(Socket, Length, Timeout) ->
    ok = inet:setopts(Socket, [{packet, raw}]),
    Result = gen_tcp:recv(Socket, Length, Timeout),
    _ = inet:setopts(Socket, [{packet, http_bin}]),
    case Result of
        {ok, Body} -> {ok, Body};
        {error, _} -> {error, nil}
    end.

target({abs_path, Path}) -> Path;
target({absoluteURI, _Scheme, _Host, _Port, Path}) -> Path;
target('*') -> <<"*">>;
target({scheme, _, Rest}) -> to_binary(Rest);
target(Other) -> to_binary(Other).

%% --- WebSockets -------------------------------------------------------------

%% Switch an upgraded socket to raw packets and deliver the next data as a
%% {tcp, Socket, Data} message.
arm_raw(Socket) ->
    _ = inet:setopts(Socket, [{packet, raw}, {active, once}]),
    nil.

%% Whether a message is the server's drain request, remembering it like
%% drain_requested/0 does.
is_drain(gloss_http_drain) ->
    put(gloss_http_draining, true),
    true;
is_drain(_) ->
    false.

%% XOR the payload with the 4-byte key repeated to its length.
unmask(_Key, <<>>) -> <<>>;
unmask(Key, Payload) ->
    Size = byte_size(Payload),
    Repeated = binary:part(binary:copy(Key, (Size + 3) div 4), 0, Size),
    crypto:exor(Payload, Repeated).

%% --- Process coordination ---------------------------------------------------

%% Whether a drain has been requested. The request is remembered, so it
%% stays true for the rest of the connection.
drain_requested() ->
    receive
        gloss_http_drain ->
            put(gloss_http_draining, true),
            true
    after 0 ->
        get(gloss_http_draining) =:= true
    end.

%% One line in `line` packet mode, without the trailing CRLF (or LF).
read_line(Socket, Timeout) ->
    ok = inet:setopts(Socket, [{packet, line}]),
    Result = gen_tcp:recv(Socket, 0, Timeout),
    _ = inet:setopts(Socket, [{packet, http_bin}]),
    case Result of
        {ok, Line} -> {ok, strip_eol(Line)};
        {error, _} -> {error, nil}
    end.

%% string:trim/3 treats CRLF as one grapheme, so strip the bytes directly.
strip_eol(Line) ->
    Size = byte_size(Line),
    case Line of
        <<Rest:(Size - 2)/binary, "\r\n">> -> Rest;
        <<Rest:(Size - 1)/binary, "\n">> -> Rest;
        _ -> Line
    end.

request_drain(Pid) ->
    Pid ! gloss_http_drain,
    nil.

%% A connection process waits for this before touching its socket, so the
%% acceptor can hand the socket over first.
await_go() ->
    receive gloss_http_go -> nil end.

go(Pid) ->
    Pid ! gloss_http_go,
    nil.

%% A server's request pipeline, kept in persistent_term so the process
%% spawned for each request reads it without copying the routes and state
%% it captures. Dropped when the server stops.
stash(Value) ->
    Key = {gloss_http_stash, make_ref()},
    persistent_term:put(Key, Value),
    Key.

unstash(Key) ->
    persistent_term:get(Key).

drop_stash(Key) ->
    _ = persistent_term:erase(Key),
    nil.

%% A flag any process can raise or read without messages, e.g. whether the
%% server is draining.
new_flag() ->
    atomics:new(1, []).

raise_flag(Flag) ->
    atomics:put(Flag, 1, 1),
    nil.

flag_raised(Flag) ->
    atomics:get(Flag, 1) =:= 1.

%% --- Handlers ---------------------------------------------------------------

%% Run a handler, turning any exception into a one-line description.
rescue(F) ->
    try
        {ok, F()}
    catch
        Class:Reason:Stack -> {error, describe_exception(Class, Reason, Stack)}
    end.

describe_exception(_, #{gleam_error := _, message := Message, module := Module,
                        function := Function, line := Line}, _) ->
    iolist_to_binary([Message, " (", Module, ".", Function, ":",
                      integer_to_binary(Line), ")"]);
describe_exception(Class, Reason, [{Module, Function, Arity, Location} | _]) ->
    Where = case proplists:get_value(line, Location) of
        undefined -> io_lib:format("~s:~s/~p", [Module, Function, arity(Arity)]);
        Line -> io_lib:format("~s:~s/~p:~p", [Module, Function, arity(Arity), Line])
    end,
    iolist_to_binary(io_lib:format("~p: ~0p (~s)", [Class, Reason, Where]));
describe_exception(Class, Reason, _) ->
    iolist_to_binary(io_lib:format("~p: ~0p", [Class, Reason])).

arity(Args) when is_list(Args) -> length(Args);
arity(Arity) -> Arity.

%% An IMF-fixdate for the `date` header, e.g. `Tue, 06 Oct 2026 12:00:00 GMT`.
%% Each process formats it at most once a second.
http_date() ->
    Now = erlang:system_time(second),
    case get(gloss_http_date) of
        {Now, Date} ->
            Date;
        _ ->
            Date = http_date(Now),
            put(gloss_http_date, {Now, Date}),
            Date
    end.

%% The same for a time in Unix seconds.
http_date(Seconds) ->
    format_date(calendar:system_time_to_universal_time(Seconds, second)).

format_date({{Y, Mo, D} = Date, {H, Mi, S}}) ->
    Day = element(calendar:day_of_the_week(Date),
                  {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}),
    Month = element(Mo, {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul",
                         "Aug", "Sep", "Oct", "Nov", "Dec"}),
    iolist_to_binary([Day, ", ", pad2(D), " ", Month, " ", integer_to_binary(Y),
                      " ", pad2(H), ":", pad2(Mi), ":", pad2(S), " GMT"]).

pad2(N) when N < 10 -> [$0, $0 + N];
pad2(N) -> integer_to_binary(N).

pdict_get(Key) ->
    case get(Key) of
        undefined -> {error, nil};
        Value -> {ok, Value}
    end.

%% --- Helpers ----------------------------------------------------------------

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value);
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value).

describe(Reason) -> iolist_to_binary(io_lib:format("~0p", [Reason])).

%% --- Compression --------------------------------------------------------------

gzip(Data) -> zlib:gzip(Data).

%% A streaming gzip compressor: a zlib port owned by the calling process.
gzip_open() ->
    Z = zlib:open(),
    ok = zlib:deflateInit(Z, default, deflated, 31, 8, default),
    Z.

%% Compress a piece and flush it, so the client can decode it at once.
gzip_chunk(Z, Data) -> iolist_to_binary(zlib:deflate(Z, Data, sync)).

gzip_finish(Z) ->
    Last = iolist_to_binary(zlib:deflate(Z, <<>>, finish)),
    _ = zlib:deflateEnd(Z),
    _ = zlib:close(Z),
    Last.

%% A streaming gzip decompressor for request bodies.
inflate_open() ->
    Z = zlib:open(),
    ok = zlib:inflateInit(Z, 31),
    Z.

%% Inflate a bounded amount: {more, Out} when there is more output from the
%% input given so far (call inflate_continue), {done, Out} once the input is
%% used up, or inflate_failed for corrupt data.
inflate(Z, Data) -> inflate_step(fun() -> zlib:safeInflate(Z, Data) end).

inflate_continue(Z) -> inflate_step(fun() -> zlib:safeInflate(Z, []) end).

inflate_step(Step) ->
    try Step() of
        {continue, Out} -> {more, iolist_to_binary(Out)};
        {finished, Out} -> {done, iolist_to_binary(Out)};
        _ -> inflate_failed
    catch
        _:_ -> inflate_failed
    end.

%% Close, reporting whether the compressed stream was complete.
inflate_end(Z) ->
    Result = try zlib:inflateEnd(Z) of
        ok -> {ok, nil}
    catch
        _:_ -> {error, nil}
    end,
    _ = zlib:close(Z),
    Result.

%% --- Peers and proxies --------------------------------------------------------

%% The connection's remote address as text, e.g. <<"203.0.113.7">>.
%% "unix" for a connection over a Unix domain socket.
peer_address(Socket) ->
    case inet:peername(Socket) of
        {ok, {local, _}} -> <<"unix">>;
        {ok, {Address, _Port}} -> list_to_binary(inet:ntoa(normalise(Address)));
        _ -> <<"">>
    end.

%% An address's bytes: 4 for IPv4 (including IPv4-mapped IPv6), 16 for IPv6.
ip_bytes(Text) ->
    case inet:parse_strict_address(binary_to_list(Text)) of
        {ok, Address} ->
            case normalise(Address) of
                {A, B, C, D} -> {ok, [A, B, C, D]};
                {A, B, C, D, E, F, G, H} ->
                    {ok, binary_to_list(<<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>)}
            end;
        {error, _} -> {error, nil}
    end.

normalise({0, 0, 0, 0, 0, 16#ffff, AB, CD}) ->
    {AB bsr 8, AB band 255, CD bsr 8, CD band 255};
normalise(Address) -> Address.

%% The position of the first Needle in Haystack.
find(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        {Position, _} -> {ok, Position};
        nomatch -> {error, nil}
    end.

%% --- Uploads ------------------------------------------------------------------

upload_open(Path) ->
    _ = filelib:ensure_dir(Path),
    case file:open(Path, [write, raw, binary]) of
        {ok, Device} -> {ok, Device};
        {error, _} -> {error, nil}
    end.

upload_write(Device, Data) ->
    case file:write(Device, Data) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

upload_close(Device) -> _ = file:close(Device), nil.

upload_rename(From, To) ->
    case file:rename(From, To) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

upload_delete(Path) -> _ = file:delete(Path), nil.

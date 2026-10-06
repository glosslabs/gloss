-module(gloss@http@server_ffi).

-export([listen/3, port/1, accept/1, controlling_process/2, close/1, send/2,
         sendfile/4, read_range/3, file_info/1, priv_dir/1, read_line/2,
         sha1/1, unmask/2, arm_raw/1, is_drain/1,
         next/2, read_body/3, drain_requested/0, request_drain/1, await_go/0,
         go/1, rescue/1, http_date/0]).

%% --- Sockets ----------------------------------------------------------------

%% Listen in `http_bin` packet mode, passive. Accepted sockets inherit the
%% options. `packet_size` bounds the request line and each header line.
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
                       {send_timeout_close, true}],
            case gen_tcp:listen(Port, Options) of
                {ok, Socket} -> {ok, Socket};
                {error, eaddrinuse} -> {error, address_in_use};
                {error, Reason} -> {error, {other, describe(Reason)}}
            end
    end.

port(Socket) ->
    {ok, Port} = inet:port(Socket),
    Port.

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
        {http, Socket, {http_request, Method, Uri, Version}} ->
            {request_line, to_binary(Method), target(Uri), Version};
        {http, Socket, {http_header, _, Name, _, Value}} ->
            {header, string:lowercase(to_binary(Name)), Value};
        {http, Socket, http_eoh} ->
            end_of_headers;
        {http, Socket, {http_error, Line}} ->
            {bad_request, to_binary(Line)};
        {tcp_closed, Socket} ->
            connection_closed;
        {tcp_error, Socket, _} ->
            connection_closed;
        gloss_http_drain ->
            drain
    after Timeout ->
        timeout
    end.

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

sha1(Data) -> crypto:hash(sha, Data).

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
http_date() ->
    {{Y, Mo, D} = Date, {H, Mi, S}} = calendar:universal_time(),
    Day = element(calendar:day_of_the_week(Date),
                  {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}),
    Month = element(Mo, {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul",
                         "Aug", "Sep", "Oct", "Nov", "Dec"}),
    iolist_to_binary(io_lib:format("~s, ~2..0w ~s ~4..0w ~2..0w:~2..0w:~2..0w GMT",
                                   [Day, D, Month, Y, H, Mi, S])).

%% --- Helpers ----------------------------------------------------------------

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value);
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value).

describe(Reason) -> iolist_to_binary(io_lib:format("~0p", [Reason])).

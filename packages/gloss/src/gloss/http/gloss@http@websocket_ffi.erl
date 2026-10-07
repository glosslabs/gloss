-module('gloss@http@websocket_ffi').
-export([writer_start/2, writer_send/4, writer_flush/2, writer_stats/1,
         writer_stop/1, writer_backlogged/1, is_writer_failed/1, push/3, group_join/2, group_leave/2, group_members/1,
         deflate_open/1, deflate/2, inflate_open/0, inflate/3]).

%% --- The writer -------------------------------------------------------------
%%
%% Each socket has a writer process that does the blocking sends, so a slow
%% client never stalls the connection's own process. Counters, shared with
%% the connection, track: 1 bytes queued, 2 messages sent, 3 bytes sent,
%% 4 set once a send failed, 5 set once a frame was refused for the limit.

-define(QUEUED, 1).
-define(MESSAGES, 2).
-define(BYTES, 3).
-define(FAILED, 4).
-define(BACKLOGGED, 5).

writer_start(Socket, MaxQueue) ->
    Owner = self(),
    Counters = counters:new(5, [write_concurrency]),
    Pid = spawn(fun() ->
        erlang:monitor(process, Owner),
        writer_loop(Socket, Counters, Owner)
    end),
    {writer, Pid, Counters, MaxQueue}.

writer_loop(Socket, C, Owner) ->
    receive
        {gloss_ws_frame, Data, Size, Counted} ->
            case 'gloss@http@server_ffi':send(Socket, Data) of
                {ok, nil} ->
                    counters:sub(C, ?QUEUED, Size),
                    counters:add(C, ?MESSAGES, Counted),
                    counters:add(C, ?BYTES, Size),
                    writer_loop(Socket, C, Owner);
                {error, nil} ->
                    counters:put(C, ?FAILED, 1),
                    Owner ! gloss_ws_writer_failed
            end;
        {gloss_ws_flush, From, Ref} ->
            From ! {Ref, flushed},
            writer_loop(Socket, C, Owner);
        {'DOWN', _, process, Owner, _} ->
            ok
    end.

%% Queue a frame. A frame that would take the queue past its limit is
%% refused, unless the queue is empty or Bypass is set (close frames).
writer_send({writer, Pid, C, Max}, Data, Counted, Bypass) ->
    Size = erlang:iolist_size(Data),
    Queued = counters:get(C, ?QUEUED),
    case counters:get(C, ?FAILED) of
        1 -> {error, send_failed};
        _ when Bypass; Queued == 0; Queued + Size =< Max ->
            counters:add(C, ?QUEUED, Size),
            Pid ! {gloss_ws_frame, Data, Size, case Counted of true -> 1; false -> 0 end},
            {ok, nil};
        _ ->
            counters:put(C, ?BACKLOGGED, 1),
            {error, queue_full}
    end.

writer_stop({writer, Pid, _, _}) ->
    exit(Pid, kill),
    nil.

%% Wait up to Timeout ms for everything queued so far to be sent.
writer_flush({writer, Pid, _, _}, Timeout) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {gloss_ws_flush, self(), Ref},
    receive
        {Ref, flushed} -> erlang:demonitor(Ref, [flush]), true;
        {'DOWN', Ref, process, _, _} -> false
    after Timeout ->
        erlang:demonitor(Ref, [flush]), false
    end.

writer_backlogged({writer, _, C, _}) ->
    counters:get(C, ?BACKLOGGED) == 1.

writer_stats({writer, _, C, _}) ->
    {counters:get(C, ?MESSAGES), counters:get(C, ?BYTES)}.

%% --- Pushes and groups ------------------------------------------------------

is_writer_failed(gloss_ws_writer_failed) -> true;
is_writer_failed(_) -> false.

push(Pid, Kind, Payload) ->
    Pid ! {gloss_ws_push, Kind, Payload},
    nil.

scope() ->
    case whereis(gloss_websocket) of
        undefined ->
            case pg:start(gloss_websocket) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok
            end;
        _ -> ok
    end,
    gloss_websocket.

group_join(Group, Pid) -> pg:join(scope(), Group, Pid), nil.

group_leave(Group, Pid) -> pg:leave(scope(), Group, Pid), nil.

group_members(Group) -> pg:get_members(scope(), Group).

%% --- permessage-deflate -----------------------------------------------------

deflate_open(WindowBits) ->
    Z = zlib:open(),
    ok = zlib:deflateInit(Z, default, deflated, -WindowBits, 8, default),
    Z.

%% Compress one message on its own (no context takeover), without the
%% trailing 00 00 ff ff the protocol drops.
deflate(Z, Data) ->
    Out = iolist_to_binary(zlib:deflate(Z, Data, sync)),
    ok = zlib:deflateReset(Z),
    Size = byte_size(Out) - 4,
    case Out of
        <<Body:Size/binary, 0, 0, 255, 255>> -> Body;
        _ -> Out
    end.

inflate_open() ->
    Z = zlib:open(),
    ok = zlib:inflateInit(Z, -15),
    Z.

%% Decompress one message, refusing to produce more than Max bytes.
inflate(Z, Data, Max) ->
    try
        Result = inflate_loop(Z, zlib:safeInflate(Z, [Data, <<0, 0, 255, 255>>]), [], 0, Max),
        ok = zlib:inflateReset(Z),
        Result
    catch
        _:_ ->
            catch zlib:inflateReset(Z),
            {error, 1007}
    end.

inflate_loop(Z, {Status, Out}, Acc, Size, Max) ->
    Size1 = Size + erlang:iolist_size(Out),
    case Size1 > Max of
        true -> {error, 1009};
        false ->
            case Status of
                continue -> inflate_loop(Z, zlib:safeInflate(Z, []), [Acc, Out], Size1, Max);
                finished -> {ok, iolist_to_binary([Acc, Out])}
            end
    end.

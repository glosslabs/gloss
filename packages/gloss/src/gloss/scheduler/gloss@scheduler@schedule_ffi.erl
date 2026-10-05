-module(gloss@scheduler@schedule_ffi).
-export([local_offset_seconds/1]).

-define(EPOCH, 62167219200).

%% The offset of the machine's local time zone from UTC, in seconds, at the
%% given unix time. Honours daylight saving transitions via the OS zone data.
local_offset_seconds(Unix) ->
    Gregorian = Unix + ?EPOCH,
    Utc = calendar:gregorian_seconds_to_datetime(Gregorian),
    Local = calendar:universal_time_to_local_time(Utc),
    calendar:datetime_to_gregorian_seconds(Local) - Gregorian.

-module(gloss@pg_ffi).
-export([pg_connection/1, coerce/1]).

%% The driver's connection record, from pool.Connection's raw field.
pg_connection({pg_connection, _, _} = Connection) -> {ok, Connection};
pg_connection(_) -> {error, nil}.

coerce(Value) -> Value.

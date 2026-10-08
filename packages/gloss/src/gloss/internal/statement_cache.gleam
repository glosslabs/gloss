//// A connection's prepared statements, by SQL text, for the database
//// drivers (`gloss_pg`, `gloss_mysql`). It keeps up to a set number,
//// evicting the least recently used; evicted ones wait in `take_closing`
//// for the driver to close them on the server with its next request.

import gleam/erlang/process.{type Pid}

pub type Cache(statement)

@external(erlang, "gloss@internal@statement_cache_ffi", "new")
pub fn new(max: Int) -> Cache(statement)

@external(erlang, "gloss@internal@statement_cache_ffi", "lookup")
pub fn lookup(cache: Cache(statement), sql: String) -> Result(statement, Nil)

@external(erlang, "gloss@internal@statement_cache_ffi", "put")
pub fn put(cache: Cache(statement), sql: String, statement: statement) -> Nil

/// Forget `sql`'s statement, queueing it to be closed.
@external(erlang, "gloss@internal@statement_cache_ffi", "delete")
pub fn delete(cache: Cache(statement), sql: String) -> Nil

/// The statements evicted or deleted since the last call.
@external(erlang, "gloss@internal@statement_cache_ffi", "take_closing")
pub fn take_closing(cache: Cache(statement)) -> List(statement)

/// A number not handed out before by this cache, e.g. for statement names.
@external(erlang, "gloss@internal@statement_cache_ffi", "next_id")
pub fn next_id(cache: Cache(statement)) -> Int

/// Make `pid` the cache's owner, so it lives as long as the connection.
@external(erlang, "gloss@internal@statement_cache_ffi", "give")
pub fn give(cache: Cache(statement), pid: Pid) -> Nil

@external(erlang, "gloss@internal@statement_cache_ffi", "drop")
pub fn drop(cache: Cache(statement)) -> Nil

//// The Postgres database: the connection pool and the schema.

import gleam/result
import gloss/pg
import gloss/sql
import gloss/tracer.{type Tracer}

pub type Error {
  InvalidUrl
  SchemaFailed(sql.Error)
}

/// Start a pool for the database at `url` and bring its schema up to date.
pub fn start(url: String, tracer: Tracer) -> Result(sql.Db, Error) {
  use config <- result.try(pg.from_url(url) |> result.replace_error(InvalidUrl))
  let assert Ok(db) =
    sql.new(pg.driver(config))
    |> sql.pool_size(10)
    |> sql.tracer(tracer)
    |> sql.start
  use Nil <- result.map(migrate(db) |> result.map_error(SchemaFailed))
  db
}

/// Create the tables and indexes that don't exist yet. Every statement is
/// safe to run again, so this runs at every start.
pub fn migrate(db: sql.Db) -> Result(Nil, sql.Error) {
  sql.script(db, schema)
}

const schema =
  "
create table if not exists users (
  id            bigserial primary key,
  email         text not null constraint users_email_key unique,
  display_name  text not null,
  bio           text not null default '',
  avatar        text,
  password_hash text not null,
  joined_at     timestamptz not null
);

create table if not exists threads (
  id            bigserial primary key,
  title         text not null,
  last_activity timestamptz not null
);

create index if not exists threads_by_activity
  on threads (last_activity desc, id desc);

create table if not exists posts (
  id        bigserial primary key,
  thread_id bigint not null references threads (id) on delete cascade,
  author_id bigint not null references users (id),
  body      text not null,
  at        timestamptz not null
);

create index if not exists posts_by_thread on posts (thread_id, id);
"

<p align="center" style="padding: 48px 0;">
    <a href="https://glosslabs.dev" target="_blank">
        <img
            src="asset/hero.svg"
            width="240">
    </a>
</p>


## About Gloss

> **Note:** Gloss is under active development and has not yet reached an initial release.

Gloss is a progressive framework for building modern web applications with [Gleam](https://gleam.run/).   

| Package | |
|---|---|
| [`gloss`](packages/gloss) | HTTP server and router, sessions, WebSockets, tracer, logger, scheduler, signals and stores |
| [`gloss_url`](packages/gloss_url) | Building and reading URLs and query strings, strictly encoded, on the BEAM and in JavaScript (`gloss/url`) |
| [`gloss_testing`](packages/gloss_testing) | Test helpers: requests, responses, a cookie-keeping browser, HTML readers, a WebSocket client, a test clock and ids (`gloss/testing/*`) |

**SQL** ([`packages/sql`](packages/sql))

| Package | |
|---|---|
| [`gloss_sql`](packages/sql/gloss_sql) | Statements, values, errors and row decoding for every driver, and a typed query builder, on the BEAM and in JavaScript (`gloss/sql`, `gloss/sql/query`) |
| [`gloss_sql_pool`](packages/sql/gloss_sql_pool) | Running statements on the BEAM through a connection pool, with transactions (`gloss/sql/pool`) |
| [`gloss_sql_async`](packages/sql/gloss_sql_async) | Running statements in JavaScript, returning Promises (`gloss/sql/async`) |
| [`gloss_pg`](packages/sql/gloss_pg) | Postgres driver for the pool (`gloss/pg`) |
| [`gloss_mysql`](packages/sql/gloss_mysql) | MySQL driver for the pool, speaking the protocol directly: caching_sha2 and native auth, TLS, prepared statements (`gloss/mysql`) |
| [`gloss_sqlite`](packages/sql/gloss_sqlite) | SQLite driver for the pool, on the esqlite NIF (`gloss/sqlite`) |
| [`gloss_sqlite_wasm`](packages/sql/gloss_sqlite_wasm) | SQLite in the browser on the official WebAssembly build, with OPFS storage (`gloss/sqlite/wasm`) |
| [`gloss_pglite`](packages/sql/gloss_pglite) | PGlite (Postgres in WebAssembly) in the browser and JavaScript runtimes, reading values exactly as `gloss_pg` does (`gloss/pglite`) |

**Clients** ([`packages/clients`](packages/clients))

| Package | |
|---|---|
| [`gloss_redis`](packages/clients/gloss_redis) | Redis client speaking RESP directly: pooled and pipelined, transactions, pub/sub (`gloss/redis`) |
| [`gloss_s3`](packages/clients/gloss_s3) | S3 client with in-house SigV4 signing: objects, listing, presigned URLs, multipart; works with AWS, R2 and other S3-compatible stores (`gloss/s3`) |

**Observability** ([`packages/observability`](packages/observability))

| Package | |
|---|---|
| [`gloss_sentry`](packages/observability/gloss_sentry) | Report failures, logs and process crashes to Sentry (`gloss/sentry`) |
| [`gloss_otel`](packages/observability/gloss_otel) | Export spans and logs to OpenTelemetry over OTLP/HTTP (`gloss/otel`) |

A package imports as its name with underscores as slashes: `gloss_sql_pool` is `gloss/sql/pool`.

[`template`](template) is the starting point for a new application, and [`examples`](examples) shows the packages in use.


## License
Gloss is open-sourced software licensed under the [MIT license](LICENSE.md).

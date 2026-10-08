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
| [`gloss`](packages/gloss) | HTTP server and router, database pool (`gloss/sql/pool`), tracer, logger, scheduler and signals |
| [`gloss_sql`](packages/gloss_sql) | SQL statements, values, errors and row decoding for every driver, on the BEAM and in JavaScript (`gloss/sql`) |
| [`gloss_pg`](packages/gloss_pg) | Postgres driver for `gloss/sql/pool` (`gloss/pg`) |
| [`gloss_mysql`](packages/gloss_mysql) | MySQL driver for `gloss/sql/pool`, speaking the protocol directly: caching_sha2 and native auth, TLS, prepared statements (`gloss/mysql`) |
| [`gloss_sql_async`](packages/gloss_sql_async) | Running `gloss/sql` statements in JavaScript, returning Promises (`gloss/sql/async`) |
| [`gloss_sqlite`](packages/gloss_sqlite) | SQLite driver for `gloss/sql/pool`, on the esqlite NIF (`gloss/sqlite`) |
| [`gloss_sqlite_wasm`](packages/gloss_sqlite_wasm) | SQLite in the browser on the official WebAssembly build, with OPFS storage (`gloss/sqlite/wasm`) |
| [`gloss_pglite`](packages/gloss_pglite) | PGlite (Postgres in WebAssembly) in the browser and JavaScript runtimes, reading values exactly as `gloss_pg` does (`gloss/pglite`) |
| [`gloss_redis`](packages/gloss_redis) | Redis client speaking RESP directly: pooled and pipelined, transactions, pub/sub (`gloss/redis`) |
| [`gloss_s3`](packages/gloss_s3) | S3 client with in-house SigV4 signing: objects, listing, presigned URLs, multipart; works with AWS, R2 and other S3-compatible stores (`gloss/s3`) |
| [`gloss_test`](packages/gloss_test) | Test helpers: requests, responses, a cookie-keeping browser, HTML readers, a WebSocket client, a test clock and ids (`gloss/testing/*`) |
| [`gloss_sentry`](packages/gloss_sentry) | Report failures to Sentry |
| [`gloss_otel`](packages/gloss_otel) | Export spans and logs to OpenTelemetry over OTLP/HTTP |

[`template`](template) is the starting point for a new application, and [`examples`](examples) shows the packages in use.


## License
Gloss is open-sourced software licensed under the [MIT license](LICENSE.md).

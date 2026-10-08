# Package benchmarks

Benchmarks for every gloss package: CPU-bound code paths, and the drivers
against live services. Each benchmark warms up, then reports the median of
five timed rounds.

```sh
gleam run                 # everything
gleam run -- cpu          # CPU-bound paths only
gleam run -- services     # drivers; SQLite always, others when their URL is set
```

The service benchmarks run when these are set:

```sh
GLOSS_BENCH_PG_URL=postgres://postgres:secret@127.0.0.1:5433/postgres
GLOSS_BENCH_MYSQL_URL=mysql://root:secret@127.0.0.1:3307/gloss
GLOSS_BENCH_REDIS_URL=redis://127.0.0.1:6390/0
GLOSS_BENCH_S3_ENDPOINT=http://127.0.0.1:9010   # access key gloss, secret glosssecret
```

The JavaScript side (gloss/sql and gloss/url on Node, SQLite WebAssembly and
PGlite) is in [`../packages_js`](../packages_js): `npm install`, then
`gleam run`. HTTP throughput is measured by [`../http/run.sh`](../http/run.sh).

## Results of the first pass (2026-10-08, Apple M5 Pro)

Changes made from what these benchmarks found:

| | Before | After |
|---|---|---|
| S3 `xml.parse`, 1000-object listing | 28.6 ms | 3.3 ms |
| SQLite query through the pool (`select 1`) | 10.4 µs | 6.6 µs |
| SQLite on a file, 50 concurrent writers | 26,922/s | 54,814/s |
| PGlite query | 127 µs | 64 µs (PGlite's own floor) |
| Postgres `timestamptz` decode | 3.5 µs | 0.37 µs |
| S3 SigV4 signing | 20.8 µs | 8.9 µs |
| `tracer.span` with a handler | 1.2 µs | 0.56 µs |
| `logger.format` | 1.6 µs | 1.1 µs |
| `url.encode`, 120 escape-heavy characters | 8.1 µs | 6.8 µs |
| `server.handle` in tests | 41 µs (compiled routes per call) | 2.1 µs with `server.handler` |

Most of the CPU fixes removed calls to `string.contains`, `split`, `trim`
and `replace` from hot paths: on the BEAM each compiles a search pattern,
which cost more than the work around it. The SQLite writer change queues
writers in the BEAM so they never fall into SQLite's sleeping busy handler.

Round trips to Docker on macOS cost about 100 µs, which is the floor for
the Postgres, MySQL and Redis numbers; the drivers add little to it, and
scale with concurrent callers (Postgres: 28.6k point reads/s through 10
connections, Redis: 132k GETs/s).

## Pipelined BEGIN

A transaction's `BEGIN` now goes with its first statement, saving a round
trip ("transaction: select and update", Docker on macOS):

| | Before | After |
|---|---|---|
| Postgres | 525 µs | 391 µs |
| MySQL | 904 µs | 788 µs |
| SQLite (no round trips, so not pipelined) | 27–31 µs | unchanged |

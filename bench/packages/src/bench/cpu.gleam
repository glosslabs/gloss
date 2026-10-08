//// CPU-bound paths in each package, with no I/O.

import bench/harness.{bench, section}
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gloss/http/body
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import gloss/internal/http_websocket_frame as frame
import gloss/logger
import gloss/meta
import gloss/otel
import gloss/otel/internal/otlp
import gloss/redis/internal/resp
import gloss/s3/internal/sigv4
import gloss/s3/internal/xml
import gloss/sentry
import gloss/sql
import gloss/sql/internal/postgres
import gloss/sql/internal/sqlite
import gloss/tracer
import gloss/url

pub fn run() -> Nil {
  http()
  observability()
  sql_core()
  codecs()
  urls()
  redis()
  s3()
}

// --- gloss/http ----------------------------------------------------------------

fn routes() -> router.Router(Nil) {
  let ok = fn(_, _) { reply.text(200, "ok") }
  range(1, 40)
  |> list.fold(router.new(), fn(r, n) {
    let n = int.to_string(n)
    r
    |> router.get("/static/page" <> n, ok)
    |> router.get("/users/:id/posts" <> n, ok)
  })
  |> router.get("/assets/*path", ok)
  |> router.post("/api/notes", fn(req, _) {
    use note <- body.json(req, decode.at(["title"], decode.string))
    reply.json(201, json.object([#("title", json.string(note))]))
  })
}

fn http() {
  section("gloss/http")
  let assert Ok(table) = router.table(routes())
  bench("router.match static (81 routes)", 200_000, fn() {
    router.match(table, http.Get, "/static/page37")
  })
  bench("router.match with a param", 200_000, fn() {
    router.match(table, http.Get, "/users/42/posts31")
  })
  bench("router.match wildcard", 200_000, fn() {
    router.match(table, http.Get, "/assets/css/app/main.css")
  })
  bench("router.match not found", 200_000, fn() {
    router.match(table, http.Get, "/nope/nothing/here")
  })

  let builder = server.new(routes(), Nil)
  let app = server.handler(builder)
  let get =
    request.new()
    |> request.set_path("/users/7/posts12")
    |> request.set_body(body.from_bits(<<>>))
  bench("server.handle GET (compiles routes each call)", 5000, fn() {
    server.handle(builder, get)
  })
  bench("server.handler GET (pipeline, text reply)", 100_000, fn() { app(get) })
  let post =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/api/notes")
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body.from_bits(<<"{\"title\":\"hello world\"}":utf8>>))
  bench("server.handler POST JSON in, JSON out", 100_000, fn() { app(post) })

  let payload = bit_array.from_string(string.repeat("x", 1024))
  let masked = mask(frame.encode(frame.TextFrame, payload))
  bench("websocket frame encode 1 KiB", 200_000, fn() {
    frame.encode(frame.TextFrame, payload)
  })
  bench("websocket frame parse 1 KiB (masked)", 200_000, fn() {
    frame.parse(masked, 16_000_000, False)
  })
  Nil
}

/// A client frame: the server frame with the mask bit and a zero key.
fn mask(server_frame: BitArray) -> BitArray {
  let assert <<first, 126, len:16, payload:bits>> = server_frame
  <<first, 254, len:16, 0:32, payload:bits>>
}

// --- tracer, logger, sentry, otel ----------------------------------------------

fn observability() {
  section("gloss/tracer, gloss/logger, gloss/sentry, gloss/otel")
  let none = tracer.new()
  bench("tracer.span, no handlers", 1_000_000, fn() {
    tracer.span(none, "app", "work", fn() { [] }, fn() { 1 })
  })
  let one = tracer.new() |> tracer.handle(fn(_) { Nil })
  bench("tracer.span, one handler", 500_000, fn() {
    tracer.span(one, "app", "work", fn() { [#("n", meta.Int(1))] }, fn() { 1 })
  })
  let discard = logger.discard()
  bench("logger.info to discard", 1_000_000, fn() {
    discard.info("hello", [#("user", meta.Int(7))])
  })
  let entry =
    logger.Entry(
      level: logger.Info,
      message: "request finished",
      meta: [#("route", meta.String("/users/:id")), #("ms", meta.Int(12))],
      at: timestamp.system_time(),
    )
  bench("logger.format an entry", 500_000, fn() { logger.format(entry) })

  let assert Ok(sentry) =
    sentry.config("https://key@o1.ingest.sentry.io/1")
    |> sentry.start(fn(_) { Error(Nil) })
  let to_sentry = sentry.handler(sentry)
  let event =
    tracer.Point(
      source: "app",
      name: "tick",
      at: timestamp.system_time(),
      meta: [],
      level: tracer.Info,
      trace: None,
    )
  bench("sentry handler (caller's cost)", 500_000, fn() { to_sentry(event) })
  let assert Ok(exporter) =
    otel.config("http://localhost:4318")
    |> otel.max_queue(1)
    |> otel.start(fn(_) { Error(Nil) })
  let to_otel = otel.handler(exporter)
  bench("otel handler (caller's cost)", 500_000, fn() { to_otel(event) })
  process.sleep(200)

  let spans =
    list.repeat(Nil, 512)
    |> list.map(fn(_) {
      otlp.span(
        source: "gloss.http",
        name: "GET /users/:id",
        trace_id: "0af7651916cd43dd8448eb211c80319c",
        span_id: "b7ad6b7169203331",
        parent_span_id: None,
        at: timestamp.system_time(),
        duration: duration.milliseconds(3),
        meta: [
          #("method", meta.String("GET")),
          #("route", meta.String("/users/:id")),
          #("status", meta.Int(200)),
        ],
        error: None,
      )
    })
  bench("otlp.traces encode 512 spans", 500, fn() {
    otlp.traces([#("service.name", meta.String("bench"))], spans)
  })
  Nil
}

// --- gloss/sql -------------------------------------------------------------------

fn sql_core() {
  section("gloss/sql")
  bench("build and render a 10-argument statement", 200_000, fn() {
    range(1, 10)
    |> list.fold(sql.query("insert into t values ("), fn(s, n) {
      s |> sql.arg(sql.Int(n)) |> sql.append(",")
    })
    |> sql.render(sql.Postgres)
  })
  let row = [
    sql.Int(1),
    sql.Text("ada@example.com"),
    sql.Bool(True),
    sql.Timestamp(timestamp.system_time()),
    sql.Float(1.5),
    sql.Null,
    sql.Text("Ada Lovelace"),
    sql.Int(42),
  ]
  let outcome = sql.Outcome(rows: list.repeat(row, 1000), affected: 1000)
  let statement =
    sql.query("")
    |> sql.returning({
      use id <- decode.field(0, decode.int)
      use email <- decode.field(1, decode.string)
      use active <- decode.field(2, decode.bool)
      use at <- decode.field(3, sql.timestamp_decoder())
      use score <- decode.field(4, decode.float)
      use bio <- decode.field(5, decode.optional(decode.string))
      use name <- decode.field(6, decode.string)
      use n <- decode.field(7, decode.int)
      decode.success(#(id, email, active, at, score, bio, name, n))
    })
  bench("decode 1000 rows of 8 columns", 500, fn() { sql.all(outcome, statement) })
  Nil
}

fn codecs() {
  section("gloss/sql internal codecs (Postgres text, SQLite)")
  let ts = <<"2026-10-08 12:30:45.123456+00":utf8>>
  bench("postgres decode timestamptz", 500_000, fn() { postgres.decode(1184, ts) })
  bench("postgres decode int4", 1_000_000, fn() {
    postgres.decode(23, <<"123456":utf8>>)
  })
  let array = <<"{\"alpha\",\"beta gamma\",\"delta\",NULL,\"eps\\\"ilon\"}":utf8>>
  bench("postgres decode text[] (5 elements)", 200_000, fn() {
    postgres.decode(1009, array)
  })
  let at = sql.Timestamp(timestamp.system_time())
  bench("postgres encode timestamp argument", 500_000, fn() {
    postgres.encode(at)
  })
  bench("sqlite decode TIMESTAMP text", 500_000, fn() {
    sqlite.decode(sqlite.Text("2026-10-08T12:30:45.123Z"), option.Some("TIMESTAMP"))
  })
  bench("sqlite decode undeclared binary", 1_000_000, fn() {
    sqlite.decode(sqlite.Binary(<<"hello":utf8>>), None)
  })
  Nil
}

// --- gloss/url -------------------------------------------------------------------

fn urls() {
  section("gloss/url")
  let text = "postgres://ada:p%40ss@db.internal:5432/app?sslmode=require&x=1"
  bench("url.parse a connection URL", 200_000, fn() { url.parse(text) })
  let assert Ok(base) = url.parse("https://api.example.com/v1")
  bench("build a URL: 3 segments, 2 params", 200_000, fn() {
    base
    |> url.segments(["users", "42", "posts"])
    |> url.query("tag", "a&b")
    |> url.query("page", "2")
    |> url.to_string
  })
  let long = string.repeat("héllo wörld/", 10)
  bench("url.encode 120 chars", 200_000, fn() { url.encode(long) })
  Nil
}

// --- gloss/redis -----------------------------------------------------------------

fn redis() {
  section("gloss/redis RESP")
  let command = [<<"SET":utf8>>, <<"user:42:name":utf8>>, <<"Ada Lovelace":utf8>>]
  bench("resp.encode SET", 1_000_000, fn() {
    resp.encode(command) |> bytes_tree.to_bit_array
  })
  let reply =
    bytes_tree.to_bit_array(bytes_tree.from_string(
      "*1000\r\n"
      <> string.repeat("$12\r\nvalue-abcdef\r\n", 1000),
    ))
  bench("resp.parse a 1000-element array", 2000, fn() { resp.parse(reply) })
  Nil
}

// --- gloss/s3 --------------------------------------------------------------------

fn s3() {
  section("gloss/s3")
  let credentials =
    sigv4.Credentials(
      access_key_id: "AKIAIOSFODNN7EXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      session_token: None,
      region: "us-east-1",
    )
  let req =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_host("bucket.s3.amazonaws.com")
    |> request.set_path("/photos/2026/october/cat.jpg")
    |> request.set_header("content-type", "image/jpeg")
    |> request.set_body(<<"small body":utf8>>)
  let now = timestamp.system_time()
  bench("sigv4.sign a PUT", 100_000, fn() {
    sigv4.sign(req, credentials, now, sigv4.sha256_hex(req.body))
  })
  let listing =
    bit_array.from_string(
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><Name>b</Name>"
      <> string.repeat(
        "<Contents><Key>photos/2026/cat-0001.jpg</Key><LastModified>2026-10-08T12:00:00.000Z</LastModified><ETag>&quot;abc&quot;</ETag><Size>1234</Size></Contents>",
        1000,
      )
      <> "</ListBucketResult>",
    )
  bench("xml.parse a 1000-object listing", 200, fn() { xml.parse(listing) })
  Nil
}

pub fn unused() -> dict.Dict(Int, Int) {
  dict.new()
}

fn range(from: Int, to: Int) -> List(Int) {
  int.range(from:, to: to + 1, with: [], run: fn(acc, n) { [n, ..acc] })
  |> list.reverse
}

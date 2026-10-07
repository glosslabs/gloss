//// A panel at the foot of every HTML page in development, showing what
//// the request did: its timing, each query, its logs and points, and the
//// requests before it.
////
//// ```gleam
//// let assert Ok(bar) = debug_bar.start()
////
//// let tracer = tracer.new() |> tracer.handle(debug_bar.handler(bar))
//// server.new(routes, state)
//// |> server.tracer(tracer)
//// |> server.logger(logger.stack([log, debug_bar.logger(bar)]))
//// |> server.with(compress.gzip)
//// |> server.with(debug_bar.middleware(bar))
//// ```
////
//// The handler records every span and point by trace, and the logger
//// records what handlers log (each handler's logger carries its request's
//// trace). The middleware adds a script and stylesheet before `</body>` of
//// each HTML response, and serves them, and the recorded data as JSON,
//// under `/_gloss/debug/`. The script fetches the data once the page has
//// loaded, so the request's own span is there too. Both are files rather
//// than inline, so they pass a `default-src 'self'` content security
//// policy.
////
//// Add the middleware after any that compress responses, so it sees the
//// page before it is compressed. Don't give the handler's logger to
//// `logger.trace_handler` as well, or every event is recorded twice.
////
//// Everything recorded is kept for ten minutes. **Use it only in
//// development**: the data includes SQL, log lines and request details,
//// and anyone who can reach the server can read it.

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/response
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import gloss/http/context.{type Context, type Middleware}
import gloss/http/reply.{type Request, type Response}
import gloss/logger.{type Logger}
import gloss/meta.{type Meta}
import gloss/tracer

type Table

/// Where recorded events live. Start one with `start`.
pub opaque type DebugBar {
  DebugBar(table: Table)
}

type Item {
  Event(tracer.Event)
  Log(logger.Entry)
}

type Message {
  Sweep
}

const prefix = "/_gloss/debug/"

const keep_ms = 600_000

const sweep_ms = 10_000

/// Start recording, in a process linked to the caller that owns the data
/// and forgets it after ten minutes.
pub fn start() -> Result(DebugBar, actor.StartError) {
  actor.new_with_initialiser(1000, fn(self: Subject(Message)) {
    let table = new_table()
    process.send_after(self, sweep_ms, Sweep)
    #(table, self)
    |> actor.initialised
    |> actor.returning(DebugBar(table))
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    let #(table, self) = state
    case message {
      Sweep -> {
        sweep(table, now_ms() - keep_ms)
        process.send_after(self, sweep_ms, Sweep)
        actor.continue(state)
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// A tracer handler that records spans and points under their trace.
pub fn handler(bar: DebugBar) -> tracer.Handler {
  fn(event) {
    case event {
      tracer.Span(trace:, ..) ->
        insert(bar.table, trace.trace_id, is_request(event), Event(event))
      tracer.Point(trace: Some(trace), ..) ->
        insert(bar.table, trace.trace_id, False, Event(event))
      tracer.Point(trace: None, ..) -> Nil
    }
  }
}

/// A log channel that records entries under their request's trace.
/// Entries written outside a request are ignored.
pub fn logger(bar: DebugBar) -> Logger {
  logger.new(fn(entry) {
    let text = fn(key) {
      case meta.get(entry.meta, key) {
        Ok(meta.String(value)) -> Ok(value)
        _ -> Error(Nil)
      }
    }
    case result.lazy_or(text("trace_id"), fn() { text("request_id") }) {
      Ok(trace_id) -> insert(bar.table, trace_id, False, Log(entry))
      Error(Nil) -> Nil
    }
  })
}

/// Serve the panel and its data, and add it to HTML responses.
pub fn middleware(bar: DebugBar) -> Middleware(state) {
  fn(handler) {
    fn(req: Request, ctx: Context(state)) {
      case req.path {
        "/_gloss/debug/" <> rest -> serve(bar, rest)
        _ -> inject(handler(req, ctx), ctx.trace.trace_id)
      }
    }
  }
}

fn serve(bar: DebugBar, path: String) -> Response {
  case path {
    "bar.js" -> asset("text/javascript; charset=utf-8", script)
    "bar.css" -> asset("text/css; charset=utf-8", stylesheet)
    "requests" ->
      reply.json(200, json.array(recent(bar.table, 30), request_json))
      |> response.set_header("cache-control", "no-store")
    "traces/" <> trace_id ->
      reply.json(
        200,
        json.object([
          #("trace_id", json.string(trace_id)),
          #("items", json.array(lookup(bar.table, trace_id), item_json)),
        ]),
      )
      |> response.set_header("cache-control", "no-store")
    _ -> reply.not_found()
  }
}

fn asset(content_type: String, body: String) -> Response {
  reply.bytes(200, content_type, bytes_tree.from_string(body))
  |> response.set_header("cache-control", "no-cache")
}

/// Add the panel before the last `</body>` of an HTML response.
fn inject(res: Response, trace_id: String) -> Response {
  let html =
    response.get_header(res, "content-type")
    |> result.map(string.starts_with(_, "text/html"))
    |> result.unwrap(False)
  let body = case res.body, html {
    reply.Text(text), True -> Ok(text)
    reply.Bytes(bytes), True ->
      bytes_tree.to_bit_array(bytes) |> bit_array.to_string
    _, _ -> Error(Nil)
  }
  case body {
    Ok(text) ->
      case split_last(text, "</body>") {
        Ok(#(before, after)) ->
          response.set_body(
            res,
            reply.Text(before <> tags(trace_id) <> "</body>" <> after),
          )
        Error(Nil) -> res
      }
    Error(Nil) -> res
  }
}

fn tags(trace_id: String) -> String {
  "<link rel=\"stylesheet\" href=\""
  <> prefix
  <> "bar.css\"><script src=\""
  <> prefix
  <> "bar.js\" data-trace=\""
  <> trace_id
  <> "\" defer></script>"
}

fn split_last(text: String, marker: String) -> Result(#(String, String), Nil) {
  case string.split(text, marker) {
    [_] | [] -> Error(Nil)
    parts -> {
      let assert Ok(after) = list.last(parts)
      let before = list.take(parts, list.length(parts) - 1)
      Ok(#(string.join(before, marker), after))
    }
  }
}

/// A request span from gloss/http, other than for the panel itself.
fn is_request(event: tracer.Event) -> Bool {
  case event {
    tracer.Span(source: "gloss.http", name:, meta:, ..) if name != "websocket" ->
      case meta.get(meta, "path") {
        Ok(meta.String(path)) -> !string.starts_with(path, prefix)
        _ -> False
      }
    _ -> False
  }
}

// --- JSON ---------------------------------------------------------------------

fn request_json(item: Item) -> Json {
  case item {
    Event(tracer.Span(name:, at:, meta:, duration:, error:, trace:, ..)) ->
      json.object([
        #("trace_id", json.string(trace.trace_id)),
        #("name", json.string(name)),
        #("at", json.float(ms(at))),
        #("duration", json.float(duration_ms(duration))),
        #("error", json.nullable(error, json.string)),
        #("meta", meta_json(meta)),
      ])
    _ -> json.null()
  }
}

fn item_json(item: Item) -> Json {
  case item {
    Event(tracer.Span(
      source:,
      name:,
      at:,
      meta:,
      duration:,
      error:,
      trace:,
      parent_span_id:,
    )) ->
      json.object([
        #("kind", json.string("span")),
        #("source", json.string(source)),
        #("name", json.string(name)),
        #("at", json.float(ms(at))),
        #("duration", json.float(duration_ms(duration))),
        #("error", json.nullable(error, json.string)),
        #("meta", meta_json(meta)),
        #("span_id", json.string(trace.span_id)),
        #("parent_span_id", json.nullable(parent_span_id, json.string)),
      ])
    Event(tracer.Point(source:, name:, at:, meta:, level:, ..)) ->
      json.object([
        #("kind", json.string("point")),
        #("source", json.string(source)),
        #("name", json.string(name)),
        #("at", json.float(ms(at))),
        #("level", json.string(tracer_level(level))),
        #("meta", meta_json(meta)),
      ])
    Log(entry) ->
      json.object([
        #("kind", json.string("log")),
        #("message", json.string(entry.message)),
        #("at", json.float(ms(entry.at))),
        #("level", json.string(logger.level_to_string(entry.level))),
        #(
          "meta",
          meta_json(
            list.filter(entry.meta, fn(e) {
              e.0 != "request_id" && e.0 != "trace_id" && e.0 != "route"
            }),
          ),
        ),
      ])
  }
}

fn meta_json(meta: Meta) -> Json {
  json.object(
    list.map(meta, fn(entry) {
      #(entry.0, case entry.1 {
        meta.String(s) -> json.string(s)
        meta.Int(i) -> json.int(i)
        meta.Float(f) -> json.float(f)
        meta.Bool(b) -> json.bool(b)
      })
    }),
  )
}

fn tracer_level(level: tracer.Level) -> String {
  case level {
    tracer.Debug -> "debug"
    tracer.Info -> "info"
    tracer.Warning -> "warning"
    tracer.Error -> "error"
  }
}

/// Milliseconds since the Unix epoch.
fn ms(at: Timestamp) -> Float {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(at)
  int.to_float(seconds) *. 1000.0 +. int.to_float(nanoseconds) /. 1_000_000.0
}

fn duration_ms(d: duration.Duration) -> Float {
  duration.to_seconds(d) *. 1000.0
}

fn now_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}

@external(erlang, "gloss@http@debug_bar_ffi", "new_table")
fn new_table() -> Table

@external(erlang, "gloss@http@debug_bar_ffi", "insert")
fn insert(table: Table, trace_id: String, is_request: Bool, item: Item) -> Nil

@external(erlang, "gloss@http@debug_bar_ffi", "lookup")
fn lookup(table: Table, trace_id: String) -> List(Item)

@external(erlang, "gloss@http@debug_bar_ffi", "recent")
fn recent(table: Table, limit: Int) -> List(Item)

@external(erlang, "gloss@http@debug_bar_ffi", "sweep")
fn sweep(table: Table, cutoff_ms: Int) -> Nil

// --- The panel ------------------------------------------------------------------

const script =
  "(() => {
  const base = '/_gloss/debug/';
  const me = document.currentScript;
  const pageTrace = me && me.dataset.trace;
  if (!pageTrace) return;

  const h = (tag, cls, text) => {
    const el = document.createElement(tag);
    if (cls) el.className = cls;
    if (text !== undefined) el.textContent = text;
    return el;
  };
  const ms = (n) => (n < 1 ? n.toFixed(2) : n < 100 ? n.toFixed(1) : Math.round(n)) + ' ms';
  const metaText = (meta) => Object.entries(meta || {}).map(([k, v]) => k + '=' + v).join(' ');
  const remember = (key, value) => { try { sessionStorage.setItem(key, value); } catch (e) {} };
  const recall = (key) => { try { return sessionStorage.getItem(key); } catch (e) { return null; } };

  const root = h('div', 'gloss-debug');
  const bar = h('button', 'gloss-debug-bar');
  bar.type = 'button';
  const panel = h('div', 'gloss-debug-panel');
  const tabs = h('div', 'gloss-debug-tabs');
  const body = h('div', 'gloss-debug-body');
  panel.append(tabs, body);
  root.append(panel, bar);
  document.body.appendChild(root);

  let open = recall('gloss-debug-open') === '1';
  let tab = recall('gloss-debug-tab') || 'timeline';
  let trace = pageTrace;
  let data = null;

  const setOpen = (value) => {
    open = value;
    remember('gloss-debug-open', open ? '1' : '0');
    root.classList.toggle('open', open);
  };
  bar.addEventListener('click', () => setOpen(!open));
  setOpen(open);

  const views = {
    timeline: 'Timeline',
    queries: 'Queries',
    logs: 'Logs',
    requests: 'Requests',
  };

  const request = (items) => items.find((i) => i.kind === 'span' && i.source === 'gloss.http' && !i.parent_span_id)
    || items.find((i) => i.kind === 'span' && i.source === 'gloss.http');
  const queries = (items) => items.filter((i) => i.kind === 'span' && i.source === 'gloss.sql');
  const logs = (items) => items.filter((i) => i.kind === 'log' || i.kind === 'point');

  function summary() {
    bar.replaceChildren();
    if (!data) { bar.append(h('span', '', 'gloss')); return; }
    const req = request(data.items);
    const qs = queries(data.items);
    const ls = logs(data.items);
    const problems = data.items.filter((i) => i.error || i.level === 'error' || i.level === 'warning').length;
    bar.append(h('span', 'gloss-debug-name', req ? req.name : 'request'));
    if (req && req.meta.status !== undefined) {
      bar.append(h('span', req.meta.status >= 500 ? 'bad' : req.meta.status >= 400 ? 'warn' : 'ok', String(req.meta.status)));
    }
    if (req) bar.append(h('span', '', ms(req.duration)));
    bar.append(h('span', '', qs.length + (qs.length === 1 ? ' query' : ' queries')));
    bar.append(h('span', '', ls.length + (ls.length === 1 ? ' log' : ' logs')));
    if (problems) bar.append(h('span', 'bad', problems + ' problem' + (problems === 1 ? '' : 's')));
    if (trace !== pageTrace) bar.append(h('span', 'warn', 'earlier request'));
  }

  function renderTabs() {
    tabs.replaceChildren();
    for (const [key, label] of Object.entries(views)) {
      const b = h('button', key === tab ? 'active' : '', label);
      b.type = 'button';
      b.addEventListener('click', () => { tab = key; remember('gloss-debug-tab', tab); render(); });
      tabs.append(b);
    }
    if (trace !== pageTrace) {
      const back = h('button', '', 'Back to this page');
      back.type = 'button';
      back.addEventListener('click', () => load(pageTrace));
      tabs.append(back);
    }
  }

  function timeline(items) {
    const spans = items.filter((i) => i.kind === 'span').sort((a, b) => a.at - b.at);
    if (!spans.length) return h('p', 'empty', 'No spans recorded.');
    const start = Math.min(...spans.map((s) => s.at));
    const end = Math.max(...spans.map((s) => s.at + s.duration));
    const total = Math.max(end - start, 0.001);
    const list = h('div', 'gloss-debug-rows');
    for (const s of spans) {
      const row = h('div', 'gloss-debug-row' + (s.error ? ' failed' : ''));
      const label = h('div', 'label', s.source + ' ' + s.name);
      label.title = metaText(s.meta) + (s.error ? ' error=' + s.error : '');
      const track = h('div', 'track');
      const fill = h('div', 'fill');
      fill.style.left = ((s.at - start) / total * 100) + '%';
      fill.style.width = Math.max(s.duration / total * 100, 0.5) + '%';
      track.append(fill);
      row.append(label, track, h('div', 'time', ms(s.duration)));
      list.append(row);
    }
    return list;
  }

  function queryList(items) {
    const qs = queries(items);
    if (!qs.length) return h('p', 'empty', 'No queries.');
    const counts = {};
    for (const q of qs) { const sql = q.meta.sql || q.name; counts[sql] = (counts[sql] || 0) + 1; }
    const total = qs.reduce((n, q) => n + q.duration, 0);
    const wrap = h('div', '');
    wrap.append(h('p', 'note', qs.length + ' queries in ' + ms(total)));
    for (const q of qs) {
      const sql = q.meta.sql || q.name;
      const row = h('div', 'gloss-debug-query' + (q.error ? ' failed' : ''));
      const head = h('div', 'head');
      head.append(h('span', '', ms(q.duration)));
      if (q.meta.rows !== undefined) head.append(h('span', '', q.meta.rows + (q.meta.rows === 1 ? ' row' : ' rows')));
      if (counts[sql] > 1) head.append(h('span', 'warn', 'run ' + counts[sql] + ' times'));
      if (q.error) head.append(h('span', 'bad', q.error));
      row.append(head, h('pre', '', sql));
      wrap.append(row);
    }
    return wrap;
  }

  function logList(items) {
    const ls = logs(items);
    if (!ls.length) return h('p', 'empty', 'Nothing logged.');
    const start = Math.min(...items.map((i) => i.at));
    const list = h('div', 'gloss-debug-rows');
    for (const l of ls) {
      const row = h('div', 'gloss-debug-log level-' + l.level);
      row.append(
        h('span', 'time', '+' + ms(l.at - start)),
        h('span', 'level', l.level),
        h('span', 'message', l.kind === 'log' ? l.message : l.source + ' ' + l.name),
        h('span', 'meta', metaText(l.meta)),
      );
      list.append(row);
    }
    return list;
  }

  function requestList(requests) {
    if (!requests.length) return h('p', 'empty', 'No requests recorded.');
    const list = h('div', 'gloss-debug-rows');
    for (const r of requests) {
      const row = h('button', 'gloss-debug-request' + (r.trace_id === trace ? ' active' : ''));
      row.type = 'button';
      const status = r.meta.status;
      row.append(
        h('span', 'time', new Date(r.at).toLocaleTimeString()),
        h('span', status >= 500 ? 'bad' : status >= 400 ? 'warn' : 'ok', String(status)),
        h('span', 'message', r.name + (r.meta.path && r.meta.route !== r.meta.path ? '  ' + r.meta.path : '')),
        h('span', 'time', ms(r.duration)),
      );
      row.addEventListener('click', () => { tab = 'timeline'; load(r.trace_id); });
      list.append(row);
    }
    return list;
  }

  async function render() {
    renderTabs();
    summary();
    body.replaceChildren();
    if (tab === 'requests') {
      try {
        const res = await fetch(base + 'requests', { cache: 'no-store' });
        body.replaceChildren(requestList(await res.json()));
      } catch (e) {
        body.replaceChildren(h('p', 'empty', 'Could not load requests.'));
      }
      return;
    }
    if (!data) { body.append(h('p', 'empty', 'Loading...')); return; }
    body.append(tab === 'queries' ? queryList(data.items) : tab === 'logs' ? logList(data.items) : timeline(data.items));
  }

  async function load(id) {
    trace = id;
    data = null;
    render();
    try {
      const res = await fetch(base + 'traces/' + encodeURIComponent(id), { cache: 'no-store' });
      data = await res.json();
    } catch (e) {
      data = { items: [] };
    }
    render();
  }

  load(pageTrace);
})();
"

const stylesheet =
  ".gloss-debug { position: fixed; right: 12px; bottom: 12px; z-index: 2147483647; display: flex; flex-direction: column; align-items: flex-end; gap: 6px; max-width: calc(100vw - 24px); font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: #e6e6e6; text-align: left; }
.gloss-debug * { box-sizing: border-box; font: inherit; color: inherit; letter-spacing: normal; text-transform: none; }
.gloss-debug button { cursor: pointer; border: 0; margin: 0; }
.gloss-debug-bar { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; padding: 6px 10px; border-radius: 8px; background: #1d1f24; box-shadow: 0 2px 10px rgba(0, 0, 0, 0.3); }
.gloss-debug-bar:hover, .gloss-debug-bar:focus-visible { background: #2a2d34; outline: none; }
.gloss-debug-name { font-weight: bold; }
.gloss-debug .ok { color: #7ee787; }
.gloss-debug .warn { color: #f2cc60; }
.gloss-debug .bad { color: #ff7b72; }
.gloss-debug-panel { display: none; width: min(900px, calc(100vw - 24px)); max-height: 55vh; flex-direction: column; border-radius: 8px; background: #16181c; box-shadow: 0 4px 24px rgba(0, 0, 0, 0.4); overflow: hidden; }
.gloss-debug.open .gloss-debug-panel { display: flex; }
.gloss-debug-tabs { display: flex; flex-wrap: wrap; gap: 2px; padding: 6px; background: #1d1f24; }
.gloss-debug-tabs button { background: none; padding: 4px 10px; border-radius: 6px; color: #a0a4ab; }
.gloss-debug-tabs button.active, .gloss-debug-tabs button:hover { background: #2a2d34; color: #e6e6e6; }
.gloss-debug-body { overflow: auto; padding: 8px 10px; }
.gloss-debug .empty, .gloss-debug .note { margin: 4px 0; color: #a0a4ab; }
.gloss-debug-rows { display: flex; flex-direction: column; gap: 2px; }
.gloss-debug-row { display: grid; grid-template-columns: minmax(120px, 30%) 1fr 70px; gap: 8px; align-items: center; }
.gloss-debug-row .label { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.gloss-debug-row .track { position: relative; height: 10px; border-radius: 3px; background: #23262c; }
.gloss-debug-row .fill { position: absolute; top: 0; bottom: 0; border-radius: 3px; background: #58a6ff; }
.gloss-debug-row.failed .fill { background: #ff7b72; }
.gloss-debug .time { color: #a0a4ab; text-align: right; white-space: nowrap; }
.gloss-debug-query { padding: 6px 0; border-bottom: 1px solid #23262c; }
.gloss-debug-query .head { display: flex; gap: 12px; color: #a0a4ab; }
.gloss-debug-query pre { margin: 4px 0 0; white-space: pre-wrap; word-break: break-word; color: #e6e6e6; }
.gloss-debug-log { display: grid; grid-template-columns: 70px 60px minmax(0, 1fr); gap: 8px; padding: 2px 0; }
.gloss-debug-log .meta { grid-column: 3; color: #a0a4ab; word-break: break-word; }
.gloss-debug-log.level-warning .level { color: #f2cc60; }
.gloss-debug-log.level-error .level { color: #ff7b72; }
.gloss-debug-request { background: none; display: grid; grid-template-columns: 90px 40px minmax(0, 1fr) 70px; gap: 8px; padding: 3px 4px; border-radius: 4px; text-align: left; }
.gloss-debug-request:hover, .gloss-debug-request.active { background: #23262c; }
.gloss-debug-request .message { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
"

//// Development reloading: rebuild when source files change, load the new
//// code into the running node, and refresh the browser.
////
//// ```gleam
//// let assert Ok(reloader) = reload.new() |> reload.tracer(tracer) |> reload.start
//// server.new(routes, state)
//// |> server.with(compress.gzip)
//// |> server.with(reload.middleware(reloader))
//// ```
////
//// The reloader looks at `src` and `priv` every 300 milliseconds. When a
//// `.gleam`, `.erl`, `.hrl` or `.mjs` file changes it runs `gleam build`,
//// then reloads every loaded module whose compiled code changed, and pages
//// served through the middleware refresh themselves. A change to anything
//// else, such as a stylesheet in `priv/static`, just refreshes them. If the
//// build fails, the compiler's output is shown over the page until a build
//// succeeds.
////
//// Handlers pick up new code on their next request, as do views and
//// anything else called from them. What was built at boot stays as it was:
//// the route table and the state, for example, so adding a route needs a
//// restart. Pages reload themselves after a restart too. A process that is
//// still running code from two reloads ago is killed when that code is
//// purged; under a supervisor it is restarted with the new code.
////
//// **Use it only in development.**

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam/time/duration.{type Duration}
import gloss/http/context.{type Context, type Middleware}
import gloss/http/reply.{type Request, type Response}
import gloss/http/sse
import gloss/meta
import gloss/tracer.{type Tracer}

pub opaque type Config {
  Config(
    directories: List(String),
    root: String,
    command: List(String),
    interval: Duration,
    tracer: Tracer,
  )
}

/// Watch `src` and `priv`, building with `gleam build` in the current
/// directory.
pub fn new() -> Config {
  Config(
    directories: ["src", "priv"],
    root: ".",
    command: ["gleam", "build"],
    interval: duration.milliseconds(300),
    tracer: tracer.new(),
  )
}

/// Watch another directory too, such as a path dependency's `src` while
/// working on it.
pub fn watch(config: Config, directory: String) -> Config {
  Config(..config, directories: list.append(config.directories, [directory]))
}

/// The build command and its arguments, run in the current directory.
/// Default `["gleam", "build"]`.
pub fn command(config: Config, command: List(String)) -> Config {
  Config(..config, command:)
}

/// How often to look for changes.
pub fn interval(config: Config, interval: Duration) -> Config {
  Config(..config, interval:)
}

/// Report each build as a `reload.built` or `reload.failed` point.
pub fn tracer(config: Config, tracer: Tracer) -> Config {
  Config(..config, tracer:)
}

/// A running reloader.
pub opaque type Reloader {
  Reloader(subject: Subject(Message))
}

/// What pages are told.
type Notice {
  Reload
  Failed(output: String)
}

type Message {
  Poll
  Subscribe(Subject(Notice))
  Down(process.Down)
}

type State {
  State(
    config: Config,
    self: Subject(Message),
    files: Dict(String, Dynamic),
    pages: Set(Subject(Notice)),
    /// The last build failed: pages opened since are told.
    failure: Result(String, Nil),
  )
}

type Dynamic

/// Start watching, in a process linked to the caller.
pub fn start(config: Config) -> Result(Reloader, actor.StartError) {
  actor.new_with_initialiser(5000, fn(self) {
    process.send_after(self, interval_ms(config), Poll)
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(Down)
    State(
      config:,
      self:,
      files: scan(config.directories, dict.new()).0,
      pages: set.new(),
      failure: Error(Nil),
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(Reloader(self))
    |> Ok
  })
  |> actor.on_message(on_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn on_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Poll -> {
      process.send_after(state.self, interval_ms(state.config), Poll)
      let #(files, changed) = scan(state.config.directories, state.files)
      case changed {
        [] -> actor.continue(State(..state, files:))
        _ -> actor.continue(rebuild(State(..state, files:), changed))
      }
    }
    Subscribe(page) -> {
      let _ =
        process.monitor(
          process.subject_owner(page) |> result.unwrap(process.self()),
        )
      case state.failure {
        Ok(output) -> process.send(page, Failed(output))
        Error(Nil) -> Nil
      }
      actor.continue(State(..state, pages: set.insert(state.pages, page)))
    }
    Down(process.ProcessDown(pid:, ..)) ->
      actor.continue(
        State(
          ..state,
          pages: set.filter(state.pages, fn(page) {
            process.subject_owner(page) != Ok(pid)
          }),
        ),
      )
    Down(process.PortDown(..)) -> actor.continue(state)
  }
}

/// Rebuild if source changed, then tell the pages.
fn rebuild(state: State, changed: List(String)) -> State {
  let source = list.any(changed, is_source)
  let config = state.config
  case source {
    False -> {
      tracer.point(
        config.tracer,
        "gloss.reload",
        "reload.assets",
        tracer.Info,
        fn() { [#("files", meta.String(string.join(changed, " ")))] },
      )
      notify(state, Reload)
      State(..state, failure: Error(Nil))
    }
    True ->
      case build(config.command, config.root) {
        Ok(_) -> {
          let modules = reload_modified()
          tracer.point(
            config.tracer,
            "gloss.reload",
            "reload.built",
            tracer.Info,
            fn() {
              [
                #("files", meta.String(string.join(changed, " "))),
                #("modules", meta.Int(list.length(modules))),
              ]
            },
          )
          notify(state, Reload)
          // The build may have rewritten files we watch; start afresh.
          let #(files, _) = scan(config.directories, state.files)
          State(..state, files:, failure: Error(Nil))
        }
        Error(output) -> {
          tracer.point(
            config.tracer,
            "gloss.reload",
            "reload.failed",
            tracer.Error,
            fn() { [#("output", meta.String(output))] },
          )
          notify(state, Failed(output))
          State(..state, failure: Ok(output))
        }
      }
  }
}

fn notify(state: State, notice: Notice) -> Nil {
  set.each(state.pages, process.send(_, notice))
}

fn is_source(path: String) -> Bool {
  list.any([".gleam", ".erl", ".hrl", ".mjs"], string.ends_with(path, _))
}

fn interval_ms(config: Config) -> Int {
  int.max(duration.to_milliseconds(config.interval), 50)
}

// --- Pages ----------------------------------------------------------------------

/// Serve the reload script and its event stream, and add the script to HTML
/// responses.
pub fn middleware(reloader: Reloader) -> Middleware(state) {
  fn(handler) {
    fn(req: Request, ctx: Context(state)) {
      case req.path {
        "/_gloss/reload/reload.js" ->
          reply.bytes(
            200,
            "text/javascript; charset=utf-8",
            bytes_tree.from_string(script),
          )
          |> response.set_header("cache-control", "no-cache")
        "/_gloss/reload/events" -> events(reloader)
        _ -> inject(handler(req, ctx))
      }
    }
  }
}

fn events(reloader: Reloader) -> Response {
  use send <- sse.stream
  let inbox = process.new_subject()
  process.send(reloader.subject, Subscribe(inbox))
  listen(send, inbox)
}

fn listen(send: sse.Send, inbox: Subject(Notice)) -> Nil {
  let event = case process.receive(inbox, 15_000) {
    Ok(Reload) -> sse.event("") |> sse.name("reload")
    Ok(Failed(output)) -> sse.event(output) |> sse.name("failed")
    Error(Nil) -> sse.keep_alive()
  }
  case send(event) {
    Ok(Nil) -> listen(send, inbox)
    Error(Nil) -> Nil
  }
}

fn inject(res: Response) -> Response {
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
  let tag = "<script src=\"/_gloss/reload/reload.js\" defer></script>"
  case body {
    Ok(text) ->
      case string.split(text, "</body>") {
        [_] | [] -> res
        parts -> {
          let assert Ok(last) = list.last(parts)
          let before = list.take(parts, list.length(parts) - 1)
          response.set_body(
            res,
            reply.Text(
              string.join(before, "</body>") <> tag <> "</body>" <> last,
            ),
          )
        }
      }
    Error(Nil) -> res
  }
}

@external(erlang, "gloss@reload_ffi", "scan")
fn scan(
  directories: List(String),
  previous: Dict(String, Dynamic),
) -> #(Dict(String, Dynamic), List(String))

@external(erlang, "gloss@reload_ffi", "build")
fn build(command: List(String), root: String) -> Result(String, String)

@external(erlang, "gloss@reload_ffi", "reload_modified")
fn reload_modified() -> List(String)

const script =
  "(() => {
  let opened = false;
  let overlay = null;
  const hide = () => { if (overlay) { overlay.remove(); overlay = null; } };
  const show = (output) => {
    hide();
    overlay = document.createElement('div');
    const s = overlay.style;
    s.position = 'fixed'; s.inset = '0'; s.zIndex = '2147483647'; s.overflow = 'auto';
    s.background = 'rgba(16, 17, 20, 0.94)'; s.color = '#f3f3f3'; s.padding = '24px';
    s.font = '13px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';
    const title = document.createElement('div');
    title.textContent = 'Build failed. Fix it and save; this page reloads when it builds.';
    title.style.color = '#ff7b72'; title.style.marginBottom = '12px'; title.style.fontWeight = 'bold';
    const pre = document.createElement('pre');
    pre.textContent = output;
    pre.style.whiteSpace = 'pre-wrap'; pre.style.margin = '0';
    const close = document.createElement('button');
    close.type = 'button'; close.textContent = 'Dismiss';
    close.style.cssText = 'position: absolute; top: 16px; right: 16px; cursor: pointer;';
    close.addEventListener('click', hide);
    overlay.append(close, title, pre);
    document.body.appendChild(overlay);
  };
  const source = new EventSource('/_gloss/reload/events');
  // After a restart the browser reconnects: the code may have changed.
  source.addEventListener('open', () => { if (opened) location.reload(); opened = true; });
  source.addEventListener('reload', () => location.reload());
  source.addEventListener('failed', (e) => show(e.data));
})();
"

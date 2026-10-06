//// Cross-site request forgery protection, from headers browsers send on
//// their own. No tokens.
////
//// ```gleam
//// router.group("/account")
//// |> router.with(csrf.protect)
////
//// // Or, trusting another origin of yours:
//// server.new(routes(), state)
//// |> server.with(csrf.new() |> csrf.trust("https://admin.example.com") |> csrf.middleware)
//// ```
////
//// Requests with a safe method (`GET`, `HEAD`, `OPTIONS`) always pass, so
//// those handlers must not change anything. For other methods:
////
//// 1. With `Sec-Fetch-Site` (every current browser sends it): `same-origin`
////    and `none` (typed in the address bar, bookmarks) pass. `same-site`
////    and `cross-site` are rejected unless `Origin` is trusted.
//// 2. Without it, an `Origin` header must name this host (or be trusted).
//// 3. With neither header the request is not from a browser, so it can't
////    be forged by a third-party page, and it passes.
////
//// Rejections are answered `403` and reported as a `Warning` point named
//// `"csrf.rejected"` from source `"gloss.http"`.

import gleam/http
import gleam/http/request
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/timestamp
import gloss/http/context.{type Context, type Handler, type Middleware}
import gloss/http/reply.{type Request}
import gloss/http/traceparent
import gloss/meta
import gloss/tracer

pub opaque type Config {
  Config(trusted: List(String))
}

/// Protection for same-origin requests only.
pub fn new() -> Config {
  Config(trusted: [])
}

/// Also accept requests from `origin`, e.g. `"https://admin.example.com"`:
/// scheme, host and any non-default port, with no path.
pub fn trust(config: Config, origin: String) -> Config {
  Config(trusted: [string.lowercase(origin), ..config.trusted])
}

pub fn middleware(config: Config) -> Middleware(state) {
  fn(next: Handler(state)) {
    fn(req: Request, ctx: Context(state)) {
      case check(config, req) {
        Ok(Nil) -> next(req, ctx)
        Error(reason) -> {
          tracer.emit(ctx.tracer, fn() {
            tracer.Point(
              source: "gloss.http",
              name: "csrf.rejected",
              at: timestamp.system_time(),
              level: tracer.Warning,
              meta: [
                #("reason", meta.String(reason)),
                #("method", meta.String(http.method_to_string(req.method))),
                #("path", meta.String(req.path)),
                #("request_id", meta.String(ctx.request_id)),
              ],
              trace: Some(traceparent.span_context(ctx.trace)),
            )
          })
          reply.error(403, "cross-origin request rejected")
        }
      }
    }
  }
}

/// `middleware(new())`: same-origin requests only.
pub fn protect(next: Handler(state)) -> Handler(state) {
  middleware(new())(next)
}

/// Whether the request may proceed, or why not.
pub fn check(config: Config, req: Request) -> Result(Nil, String) {
  let origin = request.get_header(req, "origin")
  let trusted = case origin {
    Ok(origin) -> list.contains(config.trusted, string.lowercase(origin))
    Error(Nil) -> False
  }
  case safe(req.method), request.get_header(req, "sec-fetch-site"), origin {
    True, _, _ -> Ok(Nil)
    _, _, _ if trusted -> Ok(Nil)
    _, Ok("same-origin"), _ | _, Ok("none"), _ -> Ok(Nil)
    _, Ok(site), _ -> Error("sec-fetch-site " <> site)
    _, Error(Nil), Ok(origin) ->
      case same_host(origin, request.get_header(req, "host")) {
        True -> Ok(Nil)
        False -> Error("origin " <> origin)
      }
    _, Error(Nil), Error(Nil) -> Ok(Nil)
  }
}

fn safe(method: http.Method) -> Bool {
  case method {
    http.Get | http.Head | http.Options -> True
    _ -> False
  }
}

/// Whether `origin` (`scheme://host[:port]`) names the `Host` header,
/// treating a missing port as the scheme's default.
fn same_host(origin: String, host: Result(String, Nil)) -> Bool {
  case string.split_once(string.lowercase(origin), "://"), host {
    Ok(#(scheme, authority)), Ok(host) ->
      with_port(authority, scheme) == with_port(string.lowercase(host), scheme)
    _, _ -> False
  }
}

fn with_port(authority: String, scheme: String) -> String {
  // A bracketed IPv6 host contains colons; only a colon after `]` is a port.
  let has_port = case string.split_once(authority, "]") {
    Ok(#(_, rest)) -> string.starts_with(rest, ":")
    Error(Nil) -> string.contains(authority, ":")
  }
  case has_port, scheme {
    True, _ -> authority
    False, "https" -> authority <> ":443"
    False, _ -> authority <> ":80"
  }
}

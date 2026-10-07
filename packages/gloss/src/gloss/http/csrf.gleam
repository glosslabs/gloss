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
////    Behind a reverse proxy, list it in `server.trust_proxies` so the host
////    the client used is known.
//// 3. With neither header the request is not from a browser, so it can't
////    be forged by a third-party page, and it passes.
////
//// Rejections are answered `403` and reported as a `Warning` point named
//// `"csrf.rejected"` from source `"gloss.http"`.

import gleam/http
import gleam/option.{Some}
import gleam/string
import gleam/time/timestamp
import gloss/http/context.{type Context, type Handler, type Middleware}
import gloss/http/reply.{type Request}
import gloss/http/traceparent
import gloss/internal/http_origin as origin
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
  case safe(req.method) {
    True -> Ok(Nil)
    False -> origin.check(req, config.trusted)
  }
}

fn safe(method: http.Method) -> Bool {
  case method {
    http.Get | http.Head | http.Options -> True
    _ -> False
  }
}

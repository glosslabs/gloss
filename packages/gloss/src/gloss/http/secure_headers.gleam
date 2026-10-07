//// Security headers browsers act on: a content security policy, HSTS, and
//// guards against sniffing, framing and leaky referrers.
////
//// ```gleam
//// server.new(routes(), state)
//// |> server.with(secure_headers.protect)
////
//// // Or, allowing images from a CDN and leaving HSTS to the proxy:
//// let headers =
////   secure_headers.new()
////   |> secure_headers.content_security_policy(Some(
////     "default-src 'self'; img-src 'self' https://cdn.example.com; frame-ancestors 'none'",
////   ))
////   |> secure_headers.strict_transport_security(None)
//// server.new(routes(), state)
//// |> server.with(secure_headers.middleware(headers))
//// ```
////
//// Every response gets the headers, error replies included, except where
//// the handler set one itself: a route that needs a looser policy sets its
//// own `content-security-policy` and that one is kept.
////
//// The defaults suit a server-rendered app whose scripts, styles, images
//// and fonts all come from its own origin, with no inline `<script>` or
//// `style=""`. Pages that need more must loosen the policy.

import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
import gloss/http/context.{type Context, type Handler, type Middleware}
import gloss/http/reply.{type Request}

pub opaque type Config {
  Config(
    content_security_policy: Option(String),
    strict_transport_security: Option(String),
    frame_options: Option(String),
    referrer_policy: Option(String),
    cross_origin_opener_policy: Option(String),
  )
}

/// The defaults:
///
/// - `content-security-policy: default-src 'self'; base-uri 'self';
///   form-action 'self'; frame-ancestors 'none'; object-src 'none'`
/// - `strict-transport-security: max-age=63072000; includeSubDomains`
/// - `x-frame-options: DENY`
/// - `referrer-policy: strict-origin-when-cross-origin`
/// - `cross-origin-opener-policy: same-origin`
/// - `x-content-type-options: nosniff`, always.
pub fn new() -> Config {
  Config(
    content_security_policy: Some(
      "default-src 'self'; base-uri 'self'; form-action 'self'; "
      <> "frame-ancestors 'none'; object-src 'none'",
    ),
    strict_transport_security: Some("max-age=63072000; includeSubDomains"),
    frame_options: Some("DENY"),
    referrer_policy: Some("strict-origin-when-cross-origin"),
    cross_origin_opener_policy: Some("same-origin"),
  )
}

/// Where the page may load scripts, styles, images and more from, and who
/// may frame it. `None` sends no policy.
pub fn content_security_policy(
  config: Config,
  policy: Option(String),
) -> Config {
  Config(..config, content_security_policy: policy)
}

/// Tell browsers to use only HTTPS for this host from now on, e.g.
/// `Some("max-age=31536000")`. Browsers ignore it over plain HTTP, so it is
/// harmless in development. `None` when the proxy in front sets it.
pub fn strict_transport_security(
  config: Config,
  value: Option(String),
) -> Config {
  Config(..config, strict_transport_security: value)
}

/// Who may frame the page, for browsers that predate the policy's
/// `frame-ancestors`: `Some("DENY")` or `Some("SAMEORIGIN")`.
pub fn frame_options(config: Config, value: Option(String)) -> Config {
  Config(..config, frame_options: value)
}

/// How much of the page's URL other sites see when it links to them.
pub fn referrer_policy(config: Config, policy: Option(String)) -> Config {
  Config(..config, referrer_policy: policy)
}

/// Whether pages on other origins this one opens can reach it through
/// `window.opener`. Use `Some("same-origin-allow-popups")` for OAuth or
/// payment pop-ups.
pub fn cross_origin_opener_policy(
  config: Config,
  policy: Option(String),
) -> Config {
  Config(..config, cross_origin_opener_policy: policy)
}

pub fn middleware(config: Config) -> Middleware(state) {
  let headers =
    [
      #("content-security-policy", config.content_security_policy),
      #("strict-transport-security", config.strict_transport_security),
      #("x-frame-options", config.frame_options),
      #("referrer-policy", config.referrer_policy),
      #("cross-origin-opener-policy", config.cross_origin_opener_policy),
      #("x-content-type-options", Some("nosniff")),
    ]
    |> list.filter_map(fn(header) {
      case header.1 {
        Some(value) -> Ok(#(header.0, value))
        None -> Error(Nil)
      }
    })
  fn(next: Handler(state)) {
    fn(req: Request, ctx: Context(state)) {
      let res = next(req, ctx)
      list.fold(headers, res, fn(res, header) {
        case response.get_header(res, header.0) {
          Ok(_) -> res
          Error(Nil) -> response.set_header(res, header.0, header.1)
        }
      })
    }
  }
}

/// The middleware with the defaults from `new`.
pub fn protect(next: Handler(state)) -> Handler(state) {
  middleware(new())(next)
}

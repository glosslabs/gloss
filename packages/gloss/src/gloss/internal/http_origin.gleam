//// Whether a request came from a page on this site, judged by the headers
//// browsers send on their own: `Sec-Fetch-Site`, then `Origin`. Shared by
//// CSRF protection and WebSocket upgrades.

import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gloss/http/reply.{type Request}

/// `Ok` for a same-origin request, one from a `trusted` origin (lowercase,
/// e.g. `"https://admin.example.com"`), or one from no browser at all;
/// otherwise why not.
///
/// 1. With `Sec-Fetch-Site`: `same-origin` and `none` pass; anything else
///    is refused unless `Origin` is trusted.
/// 2. Without it, an `Origin` header must name this host or be trusted.
/// 3. With neither header the request is not from a browser, so a
///    third-party page can't have sent it, and it passes.
pub fn check(req: Request, trusted: List(String)) -> Result(Nil, String) {
  let origin = request.get_header(req, "origin")
  let is_trusted = case origin {
    Ok(origin) -> list.contains(trusted, string.lowercase(origin))
    Error(Nil) -> False
  }
  case request.get_header(req, "sec-fetch-site"), origin {
    _, _ if is_trusted -> Ok(Nil)
    Ok("same-origin"), _ | Ok("none"), _ -> Ok(Nil)
    Ok(site), _ -> Error("sec-fetch-site " <> site)
    Error(Nil), Ok(origin) ->
      case same_host(origin, host(req)) {
        True -> Ok(Nil)
        False -> Error("origin " <> origin)
      }
    Error(Nil), Error(Nil) -> Ok(Nil)
  }
}

/// The host the client asked for: `req.host` and `req.port`, which follow
/// trusted proxies' forwarding headers (see `server.trust_proxies`).
fn host(req: Request) -> Result(String, Nil) {
  case req.host, req.port {
    "", _ -> Error(Nil)
    host, Some(port) -> Ok(host <> ":" <> int.to_string(port))
    host, None -> Ok(host)
  }
}

/// Whether `origin` (`scheme://host[:port]`) names the requested host,
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
    False, "https" | False, "wss" -> authority <> ":443"
    False, _ -> authority <> ":80"
  }
}

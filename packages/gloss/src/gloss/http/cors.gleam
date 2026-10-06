//// Cross-origin resource sharing: let pages on other origins call the API.
////
//// ```gleam
//// let cors =
////   cors.new()
////   |> cors.origins(cors.Listed(["https://app.example.com"]))
////   |> cors.allow_credentials(True)
////
//// server.new(routes(), state)
//// |> server.with(cors.middleware(cors))
//// ```
////
//// Attach it with `server.with`, not `router.with`: browsers send a
//// preflight `OPTIONS` request before many cross-origin calls, and it must
//// be answered even though no route handles `OPTIONS`.
////
//// For a request from an allowed origin, the middleware answers preflights
//// itself with `204` and the `access-control-allow-*` headers, and adds
//// `access-control-allow-origin` (plus `-credentials` and `-expose-headers`
//// when configured) to the handler's response. Requests from other origins
//// get no CORS headers, so the browser keeps their responses from the page.
//// Requests without an `Origin` header pass through untouched.

import gleam/http.{type Method}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloss/http/context.{type Context, type Handler, type Middleware}
import gloss/http/reply.{type Request, type Response}

pub opaque type Config {
  Config(
    origins: Origins,
    methods: List(Method),
    headers: List(String),
    expose: List(String),
    credentials: Bool,
    max_age: Option(Int),
  )
}

/// Which origins may call the API.
pub type Origins {
  /// These origins, e.g. `"https://app.example.com"`: scheme, host and any
  /// non-default port, with no path.
  Listed(List(String))
  /// Every origin. Fine for public, read-only APIs.
  Any
  /// Origins that pass the check, e.g. any subdomain of yours.
  When(fn(String) -> Bool)
}

/// No origins allowed yet. Methods `GET`, `HEAD`, `POST`, `PUT`, `PATCH`
/// and `DELETE`; request headers `content-type` and `authorization`;
/// preflights cached for 10 minutes; no credentials.
pub fn new() -> Config {
  Config(
    origins: Listed([]),
    methods: [http.Get, http.Head, http.Post, http.Put, http.Patch, http.Delete],
    headers: ["content-type", "authorization"],
    expose: [],
    credentials: False,
    max_age: Some(600),
  )
}

/// Which origins may call the API.
pub fn origins(config: Config, origins: Origins) -> Config {
  let origins = case origins {
    Listed(listed) -> Listed(list.map(listed, string.lowercase))
    other -> other
  }
  Config(..config, origins:)
}

/// The methods cross-origin requests may use.
pub fn allow_methods(config: Config, methods: List(Method)) -> Config {
  Config(..config, methods:)
}

/// The request headers cross-origin requests may send, besides the ones
/// browsers always allow.
pub fn allow_headers(config: Config, headers: List(String)) -> Config {
  Config(..config, headers: list.map(headers, string.lowercase))
}

/// Response headers the page may read, besides the ones browsers always
/// expose.
pub fn expose_headers(config: Config, headers: List(String)) -> Config {
  Config(..config, expose: headers)
}

/// Let requests carry cookies and HTTP authentication. The response then
/// names the origin rather than `*`, as browsers require.
pub fn allow_credentials(config: Config, allow: Bool) -> Config {
  Config(..config, credentials: allow)
}

/// How long browsers may cache a preflight answer, in seconds. `None`
/// leaves it to the browser (a few seconds).
pub fn max_age(config: Config, seconds: Option(Int)) -> Config {
  Config(..config, max_age: seconds)
}

pub fn middleware(config: Config) -> Middleware(state) {
  fn(next: Handler(state)) {
    fn(req: Request, ctx: Context(state)) {
      case request.get_header(req, "origin") {
        Error(Nil) -> next(req, ctx)
        Ok(origin) -> {
          let allowed = allowed(config, origin)
          let preflight =
            req.method == http.Options
            && result.is_ok(request.get_header(
              req,
              "access-control-request-method",
            ))
          case preflight {
            True -> answer_preflight(config, req, origin, allowed)
            False ->
              next(req, ctx)
              |> add_vary("origin")
              |> with_origin(config, origin, allowed)
              |> with_exposed(config, allowed)
          }
        }
      }
    }
  }
}

fn answer_preflight(
  config: Config,
  req: Request,
  origin: String,
  allowed: Bool,
) -> Response {
  let method =
    request.get_header(req, "access-control-request-method")
    |> result.unwrap("")
  let requested =
    request.get_header(req, "access-control-request-headers")
    |> result.unwrap("")
    |> string.split(",")
    |> list.map(fn(header) { string.lowercase(string.trim(header)) })
    |> list.filter(fn(header) { header != "" })
  let ok =
    allowed
    && list.any(config.methods, fn(m) { http.method_to_string(m) == method })
    && list.all(requested, list.contains(config.headers, _))
  let res =
    reply.empty(204)
    |> add_vary("origin")
    |> add_vary("access-control-request-method")
    |> add_vary("access-control-request-headers")
  case ok {
    False -> res
    True -> {
      let res =
        res
        |> with_origin(config, origin, True)
        |> response.set_header(
          "access-control-allow-methods",
          config.methods |> list.map(http.method_to_string) |> string.join(", "),
        )
      let res = case config.headers {
        [] -> res
        headers ->
          response.set_header(
            res,
            "access-control-allow-headers",
            string.join(headers, ", "),
          )
      }
      case config.max_age {
        Some(seconds) ->
          response.set_header(
            res,
            "access-control-max-age",
            int.to_string(seconds),
          )
        None -> res
      }
    }
  }
}

fn allowed(config: Config, origin: String) -> Bool {
  case config.origins {
    Any -> True
    Listed(origins) -> list.contains(origins, string.lowercase(origin))
    When(check) -> check(origin)
  }
}

fn with_origin(
  res: Response,
  config: Config,
  origin: String,
  allowed: Bool,
) -> Response {
  case allowed, config.origins, config.credentials {
    False, _, _ -> res
    True, Any, False ->
      response.set_header(res, "access-control-allow-origin", "*")
    True, _, credentials -> {
      let res = response.set_header(res, "access-control-allow-origin", origin)
      case credentials {
        True ->
          response.set_header(res, "access-control-allow-credentials", "true")
        False -> res
      }
    }
  }
}

fn with_exposed(res: Response, config: Config, allowed: Bool) -> Response {
  case allowed, config.expose {
    True, [_, ..] ->
      response.set_header(
        res,
        "access-control-expose-headers",
        string.join(config.expose, ", "),
      )
    _, _ -> res
  }
}

fn add_vary(res: Response, header: String) -> Response {
  case response.get_header(res, "vary") {
    Ok(existing) ->
      case string.contains(string.lowercase(existing), header) {
        True -> res
        False -> response.set_header(res, "vary", existing <> ", " <> header)
      }
    Error(Nil) -> response.set_header(res, "vary", header)
  }
}

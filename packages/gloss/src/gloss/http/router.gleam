//// Routes from method and path to handler.
////
//// A `Router` is a value: build groups of routes that share a prefix and
//// middleware, then combine them into the application's router.
////
//// ```gleam
//// pub fn routes() -> Router(App) {
////   let public =
////     router.new()
////     |> router.get("/health", health.show)
////
////   let notes =
////     router.group("/notes")
////     |> router.with(auth.authenticate)
////     |> router.get("/", notes.index)
////     |> router.get("/:id", notes.show)
////
////   router.combine([public, notes])
//// }
//// ```
////
//// ## Paths
////
//// A path is a list of segments separated by `/`. A segment is static
//// text, a `:param` that captures one segment, or a trailing `*name` that
//// captures one or more remaining segments joined by `/`. Captured values
//// are percent-decoded. Empty segments are ignored, so `/notes/` and
//// `/notes` are the same route.
////
//// When several routes match a path, static segments win over params and
//// params over wildcards, but a better path match without the request's
//// method gives way to a worse one with it. A path that matches only with
//// other methods is answered `405` with an `Allow` header; one that matches
//// nothing is answered `404`. `HEAD` is served by the `GET` route when
//// there is no `HEAD` route.

import gleam/dict.{type Dict}
import gleam/http.{type Method}
import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloss/http/context.{type Handler, type Middleware}
import gloss/http/reply
import gloss/internal/http_router_trie.{type Segment, Found, Missing, NotAllowed} as router_trie

pub opaque type Router(app) {
  Router(
    prefix: List(Segment),
    middleware: List(Middleware(app)),
    /// Newest first.
    routes: List(Route(app)),
    not_found: Option(Handler(app)),
    method_not_allowed: Option(fn(List(Method)) -> Handler(app)),
  )
}

type Route(app) {
  Route(
    method: Method,
    segments: List(Segment),
    handler: Handler(app),
    /// Outermost first.
    middleware: List(Middleware(app)),
    description: Option(String),
  )
}

/// A router with no prefix and no routes. The same as `group("/")`.
pub fn new() -> Router(app) {
  group("/")
}

/// A router whose routes all start with `prefix`. The prefix may contain
/// `:params`.
///
/// Panics when the prefix is not a valid path.
pub fn group(prefix: String) -> Router(app) {
  Router(
    prefix: parse_or_panic(prefix),
    middleware: [],
    routes: [],
    not_found: None,
    method_not_allowed: None,
  )
}

/// Wrap every route in this router with `middleware`, including routes
/// added after this call. Middleware attached first runs outermost.
pub fn with(router: Router(app), middleware: Middleware(app)) -> Router(app) {
  Router(..router, middleware: list.append(router.middleware, [middleware]))
}

/// Add a route for any method.
///
/// Panics when the path is not a valid path.
pub fn route(
  router: Router(app),
  method: Method,
  path: String,
  handler: Handler(app),
) -> Router(app) {
  let route =
    Route(
      method:,
      segments: list.append(router.prefix, parse_or_panic(path)),
      handler:,
      middleware: [],
      description: None,
    )
  Router(..router, routes: [route, ..router.routes])
}

pub fn get(router: Router(app), path: String, handler: Handler(app)) {
  route(router, http.Get, path, handler)
}

pub fn post(router: Router(app), path: String, handler: Handler(app)) {
  route(router, http.Post, path, handler)
}

pub fn put(router: Router(app), path: String, handler: Handler(app)) {
  route(router, http.Put, path, handler)
}

pub fn patch(router: Router(app), path: String, handler: Handler(app)) {
  route(router, http.Patch, path, handler)
}

pub fn delete(router: Router(app), path: String, handler: Handler(app)) {
  route(router, http.Delete, path, handler)
}

pub fn head(router: Router(app), path: String, handler: Handler(app)) {
  route(router, http.Head, path, handler)
}

pub fn options(router: Router(app), path: String, handler: Handler(app)) {
  route(router, http.Options, path, handler)
}

/// Describe the most recently added route, for `inspect`. Does nothing when
/// no route has been added.
pub fn describe(router: Router(app), description: String) -> Router(app) {
  case router.routes {
    [] -> router
    [last, ..rest] ->
      Router(..router, routes: [
        Route(..last, description: Some(description)),
        ..rest
      ])
  }
}

/// Answer unmatched paths with `handler` instead of the default
/// `{"error": "not found"}`. When combined, the first router that sets one
/// wins.
pub fn not_found(router: Router(app), handler: Handler(app)) -> Router(app) {
  Router(..router, not_found: Some(handler))
}

/// Answer paths that match only with other methods using the handler made
/// from the allowed methods, instead of the default JSON `405`. When
/// combined, the first router that sets one wins.
pub fn method_not_allowed(
  router: Router(app),
  handler: fn(List(Method)) -> Handler(app),
) -> Router(app) {
  Router(..router, method_not_allowed: Some(handler))
}

/// One router with every route of `routers`. Each router's prefix and
/// middleware stay with its own routes, so groups never affect each other.
/// The result can itself be combined.
pub fn combine(routers: List(Router(app))) -> Router(app) {
  Router(
    prefix: [],
    middleware: [],
    routes: list.flat_map(list.reverse(routers), flatten),
    not_found: list.find_map(routers, fn(r) {
      option.to_result(r.not_found, Nil)
    })
      |> option.from_result,
    method_not_allowed: list.find_map(routers, fn(r) {
      option.to_result(r.method_not_allowed, Nil)
    })
      |> option.from_result,
  )
}

/// The router's routes, newest first, with its own middleware moved onto
/// each of them.
fn flatten(router: Router(app)) -> List(Route(app)) {
  use route <- list.map(router.routes)
  Route(..route, middleware: list.append(router.middleware, route.middleware))
}

// --- Matching ----------------------------------------------------------------

/// A router prepared for matching. Build it once with `table`.
pub opaque type Table(app) {
  Table(
    trie: router_trie.Trie(#(String, Handler(app))),
    not_found: Handler(app),
    method_not_allowed: fn(List(Method)) -> Handler(app),
  )
}

pub type RouteError {
  /// Two routes share a method and path. Param names do not distinguish
  /// paths, so `/notes/:id` and `/notes/:slug` are the same path.
  DuplicateRoute(method: Method, path: String)
}

pub type Match(app) {
  /// `handler` already includes the route's middleware.
  Matched(route: String, params: Dict(String, String), handler: Handler(app))
  MethodNotAllowed(allowed: List(Method), handler: Handler(app))
  NotFound(handler: Handler(app))
}

/// Prepare a router for matching, reporting every duplicate route.
pub fn table(router: Router(app)) -> Result(Table(app), List(RouteError)) {
  let routes = list.reverse(flatten(router))
  let #(trie, errors) =
    list.fold(routes, #(router_trie.new(), []), fn(acc, route) {
      let #(trie, errors) = acc
      let template = router_trie.to_template(route.segments)
      let handler = wrap(route.handler, route.middleware)
      case
        router_trie.insert(trie, route.method, route.segments, #(
          template,
          handler,
        ))
      {
        Ok(trie) -> #(trie, errors)
        Error(Nil) -> #(trie, [DuplicateRoute(route.method, template), ..errors])
      }
    })
  let errors = list.reverse(errors)
  case errors {
    [] ->
      Ok(Table(
        trie:,
        not_found: option.unwrap(router.not_found, fn(_, _) {
          reply.not_found()
        }),
        method_not_allowed: option.unwrap(
          router.method_not_allowed,
          default_method_not_allowed,
        ),
      ))
    _ -> Error(errors)
  }
}

/// Whether the router can be served: no duplicate routes.
pub fn check(router: Router(app)) -> Result(Nil, List(RouteError)) {
  table(router) |> result.replace(Nil)
}

/// Find the handler for a method and request path (without the query).
pub fn match(table: Table(app), method: Method, path: String) -> Match(app) {
  case router_trie.lookup(table.trie, method, router_trie.split(path)) {
    Found(value: #(route, handler), params:) ->
      Matched(route:, params: dict.from_list(params), handler:)
    NotAllowed(allowed:) ->
      MethodNotAllowed(allowed:, handler: table.method_not_allowed(allowed))
    Missing -> NotFound(handler: table.not_found)
  }
}

fn default_method_not_allowed(allowed: List(Method)) -> Handler(app) {
  fn(_, _) {
    reply.error(405, "method not allowed")
    |> response.set_header("allow", allow_header(allowed))
  }
}

/// The methods as an `Allow` header value, e.g. `"GET, HEAD, POST"`.
pub fn allow_header(methods: List(Method)) -> String {
  methods |> list.map(http.method_to_string) |> string.join(", ")
}

fn wrap(
  handler: Handler(app),
  middleware: List(Middleware(app)),
) -> Handler(app) {
  list.fold_right(middleware, handler, fn(handler, middleware) {
    middleware(handler)
  })
}

// --- Introspection -----------------------------------------------------------

pub type RouteInfo {
  RouteInfo(method: Method, path: String, description: Option(String))
}

/// Every route, in the order it was added.
pub fn inspect(router: Router(app)) -> List(RouteInfo) {
  use route <- list.map(list.reverse(flatten(router)))
  RouteInfo(
    method: route.method,
    path: router_trie.to_template(route.segments),
    description: route.description,
  )
}

/// The methods that have a route for this request path, sorted. Includes
/// `HEAD` wherever `GET` is routed.
pub fn allowed_methods(table: Table(app), path: String) -> List(Method) {
  // Look up a method no route uses: every matching path reports its methods.
  let probe = http.Other("gloss-allowed-methods")
  case router_trie.lookup(table.trie, probe, router_trie.split(path)) {
    NotAllowed(allowed:) -> allowed
    Found(..) | Missing -> []
  }
}

fn parse_or_panic(path: String) -> List(Segment) {
  case router_trie.parse(path) {
    Ok(segments) -> segments
    Error(reason) -> panic as { "invalid route path " <> path <> ": " <> reason }
  }
}

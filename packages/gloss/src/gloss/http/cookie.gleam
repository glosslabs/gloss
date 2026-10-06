//// Reading and setting cookies.
////
//// ```gleam
//// case cookie.get(req, "theme") {
////   Ok(theme) -> ...
////   Error(Nil) -> ...
//// }
////
//// reply.empty(204)
//// |> cookie.set("theme", "dark", cookie.defaults())
//// ```
////
//// Names and values must be cookie tokens: no spaces, `;`, `,` or quotes.
//// Malformed cookies sent by clients are ignored.

import gleam/http/cookie as http_cookie
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gloss/http/reply.{type Request, type Response}

pub type Attributes =
  http_cookie.Attributes

pub type SameSite =
  http_cookie.SameSitePolicy

/// `Path=/`, `Secure`, `HttpOnly` and `SameSite=Lax`, with no expiry, so the
/// cookie lasts for the browser session.
///
/// `Secure` is on even for plain HTTP, because the server usually sits
/// behind a proxy that terminates TLS. Browsers accept secure cookies from
/// `http://localhost`, except Safari. For Safari in development use
/// `Attributes(..cookie.defaults(), secure: False)`.
pub fn defaults() -> Attributes {
  http_cookie.Attributes(
    max_age: None,
    domain: None,
    path: Some("/"),
    secure: True,
    http_only: True,
    same_site: Some(http_cookie.Lax),
  )
}

/// The same as `defaults`, expiring after `seconds`.
pub fn max_age(attributes: Attributes, seconds: Int) -> Attributes {
  http_cookie.Attributes(..attributes, max_age: Some(seconds))
}

/// The value of the cookie `name` sent with the request.
pub fn get(req: Request, name: String) -> Result(String, Nil) {
  request.get_cookies(req) |> list.key_find(name)
}

/// Every cookie sent with the request, in order.
pub fn all(req: Request) -> List(#(String, String)) {
  request.get_cookies(req)
}

/// Ask the client to store a cookie. Setting several cookies adds one
/// `set-cookie` header each.
pub fn set(
  res: Response,
  name: String,
  value: String,
  attributes: Attributes,
) -> Response {
  response.set_cookie(res, name, value, attributes)
}

/// Ask the client to delete a cookie. `attributes` must have the same path
/// and domain the cookie was set with.
pub fn delete(res: Response, name: String, attributes: Attributes) -> Response {
  response.expire_cookie(res, name, attributes)
}

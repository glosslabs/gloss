//// Server-side sessions: the client holds a random id in a cookie and the
//// data stays in a `Store` on the server.
////
//// ```gleam
//// // At boot, given to the server:
//// let assert Ok(store) = memory.start()
//// server.new(routes(), state) |> server.sessions(session.new(store))
////
//// // In a handler:
//// pub fn login(req: Request, ctx: Context(State)) -> Response {
////   use input <- body.json(req, login_decoder())
////   use session <- session.load(req, ctx.sessions)
////   session
////   |> session.regenerate
////   |> session.set("user_id", input.user_id)
////   |> session.save(reply.empty(204))
//// }
//// ```
////
//// Loading never writes anything. A session is stored, and its cookie set,
//// only when a handler calls `save`; each save also restarts its time to
//// live. A session that is never saved costs nothing, so requests from
//// clients that ignore cookies don't fill the store.
////
//// Call `regenerate` when the user's privileges change, such as at login,
//// so an id known before login can't be used after it.
////
//// Two stores come with gloss: `session/memory` keeps sessions in memory
//// until the node stops, and `session/file` also writes them to a file so
//// they survive restarts.

import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/float
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import gloss/clock.{type Clock}
import gloss/http/cookie.{type Attributes}
import gloss/http/reply.{type Request, type Response}

/// Where session data lives. `load` is given the current time and must not
/// return a session that expired before it.
pub type Store {
  Store(
    load: fn(String, Timestamp) -> Result(Dict(String, String), Nil),
    save: fn(String, Dict(String, String), Timestamp) -> Nil,
    delete: fn(String) -> Nil,
  )
}

/// How sessions are stored and identified. Build one at boot with `new`.
pub opaque type Sessions {
  Sessions(
    store: Store,
    cookie_name: String,
    ttl: Duration,
    attributes: Attributes,
    clock: Clock,
  )
}

pub opaque type Session {
  Session(
    sessions: Sessions,
    id: String,
    data: Dict(String, String),
    /// The id the client sent, if it named a live session.
    loaded: Option(String),
  )
}

/// Sessions for a server that wasn't given any (see `server.sessions`):
/// every visitor is new, and saving a session fails with an error that
/// says to configure them.
pub fn unconfigured() -> Sessions {
  new(
    Store(
      load: fn(_, _) { Error(Nil) },
      save: fn(_, _, _) {
        panic as "sessions are not configured: pass them to server.sessions"
      },
      delete: fn(_) { Nil },
    ),
  )
}

/// Defaults: cookie `session` with `cookie.defaults()`, lasting 14 days
/// from the last save.
pub fn new(store: Store) -> Sessions {
  Sessions(
    store:,
    cookie_name: "session",
    ttl: duration.hours(24 * 14),
    attributes: cookie.defaults(),
    clock: clock.system(),
  )
}

pub fn cookie_name(sessions: Sessions, name: String) -> Sessions {
  Sessions(..sessions, cookie_name: name)
}

/// How long a session lives after its last save.
pub fn ttl(sessions: Sessions, ttl: Duration) -> Sessions {
  Sessions(..sessions, ttl:)
}

/// The clock that times sessions out, for tests. Default `clock.system()`.
pub fn clock(sessions: Sessions, clock: Clock) -> Sessions {
  Sessions(..sessions, clock:)
}

/// The cookie's attributes. Its `max_age` is always set from `ttl`.
pub fn cookie_attributes(
  sessions: Sessions,
  attributes: Attributes,
) -> Sessions {
  Sessions(..sessions, attributes:)
}

/// Continue with the request's session, or a new empty one when the client
/// sent no cookie or its session has expired.
pub fn load(req: Request, sessions: Sessions, next: fn(Session) -> a) -> a {
  let existing = case cookie.get(req, sessions.cookie_name) {
    Ok(id) ->
      case sessions.store.load(id, clock.now(sessions.clock)) {
        Ok(data) -> Some(#(id, data))
        Error(Nil) -> None
      }
    Error(Nil) -> None
  }
  next(case existing {
    Some(#(id, data)) -> Session(sessions:, id:, data:, loaded: Some(id))
    None -> Session(sessions:, id: new_id(), data: dict.new(), loaded: None)
  })
}

/// Whether the client had no live session.
pub fn is_new(session: Session) -> Bool {
  session.loaded == None
}

pub fn get(session: Session, key: String) -> Result(String, Nil) {
  dict.get(session.data, key)
}

pub fn set(session: Session, key: String, value: String) -> Session {
  Session(..session, data: dict.insert(session.data, key, value))
}

pub fn remove(session: Session, key: String) -> Session {
  Session(..session, data: dict.delete(session.data, key))
}

/// Give the session a new id, keeping its data. The old id stops working
/// when the session is saved.
pub fn regenerate(session: Session) -> Session {
  Session(..session, id: new_id())
}

/// Store the session, restarting its time to live, and set its cookie on
/// the response.
pub fn save(session: Session, res: Response) -> Response {
  let Sessions(store:, ttl:, ..) = session.sessions
  case session.loaded {
    Some(old) if old != session.id -> store.delete(old)
    _ -> Nil
  }
  store.save(
    session.id,
    session.data,
    timestamp.add(clock.now(session.sessions.clock), ttl),
  )
  cookie.set(res, session.sessions.cookie_name, session.id, attributes(session))
}

/// Delete the session from the store and ask the client to drop its cookie,
/// e.g. at logout.
pub fn destroy(session: Session, res: Response) -> Response {
  case session.loaded {
    Some(id) -> session.sessions.store.delete(id)
    None -> Nil
  }
  cookie.delete(res, session.sessions.cookie_name, session.sessions.attributes)
}

/// The request's session data as stored before the request (from its
/// cookie) or after it (from the cookie the response sets, else the
/// request's). `None` when there is no live session. For gloss/http's
/// debug bar.
@internal
pub fn peek(
  sessions: Sessions,
  req: Request,
  res: Option(Response),
) -> Option(Dict(String, String)) {
  let id = case res {
    Some(res) ->
      case response_cookie(res, sessions.cookie_name) {
        Ok("") -> Error(Nil)
        Ok(id) -> Ok(id)
        Error(Nil) -> cookie.get(req, sessions.cookie_name)
      }
    None -> cookie.get(req, sessions.cookie_name)
  }
  case id {
    Ok(id) ->
      sessions.store.load(id, clock.now(sessions.clock)) |> option.from_result
    Error(Nil) -> None
  }
}

/// The value a response's `set-cookie` gives cookie `name`.
fn response_cookie(res: Response, name: String) -> Result(String, Nil) {
  res.headers
  |> list.find_map(fn(header) {
    case header {
      #("set-cookie", value) ->
        case string.split_once(value, "=") {
          Ok(#(cookie_name, rest)) if cookie_name == name ->
            case string.split_once(rest, ";") {
              Ok(#(value, _)) -> Ok(value)
              Error(Nil) -> Ok(rest)
            }
          _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

fn attributes(session: Session) -> Attributes {
  let seconds = duration.to_seconds(session.sessions.ttl)
  cookie.max_age(session.sessions.attributes, Some(float.truncate(seconds)))
}

/// 32 random bytes, base64url without padding: safe in a cookie.
fn new_id() -> String {
  crypto.strong_random_bytes(32) |> bit_array.base64_url_encode(False)
}

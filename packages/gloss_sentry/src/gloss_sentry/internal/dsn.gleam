//// Sentry DSN parsing. `{scheme}://{public_key}[:{secret}]@{host}[:port]{path}/{project_id}`.

import gleam/http.{type Scheme}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Dsn {
  Dsn(
    scheme: Scheme,
    host: String,
    port: Option(Int),
    /// Any path prefix before the project id, without a trailing slash.
    /// Empty for hosted Sentry.
    path: String,
    public_key: String,
    project_id: String,
  )
}

pub type DsnError {
  Unparseable
  MissingScheme
  MissingHost
  MissingPublicKey
  MissingProjectId
}

/// The secret key, if present, is legacy and ignored.
pub fn parse(dsn: String) -> Result(Dsn, DsnError) {
  use u <- result.try(uri.parse(dsn) |> result.replace_error(Unparseable))
  use scheme <- result.try(case u.scheme {
    Some("https") -> Ok(http.Https)
    Some("http") -> Ok(http.Http)
    _ -> Error(MissingScheme)
  })
  use host <- result.try(case u.host {
    Some("") | None -> Error(MissingHost)
    Some(host) -> Ok(host)
  })
  use public_key <- result.try(case u.userinfo {
    None -> Error(MissingPublicKey)
    Some(info) ->
      case string.split_once(info, ":") {
        Ok(#(key, _secret)) -> non_empty(key, MissingPublicKey)
        Error(Nil) -> non_empty(info, MissingPublicKey)
      }
  })
  use #(path, project_id) <- result.try(
    case list.reverse(uri.path_segments(u.path)) {
      [project_id, ..prefix] -> Ok(#(join(list.reverse(prefix)), project_id))
      [] -> Error(MissingProjectId)
    },
  )
  Ok(Dsn(scheme:, host:, port: u.port, path:, public_key:, project_id:))
}

/// Where envelopes are POSTed.
pub fn envelope_path(dsn: Dsn) -> String {
  dsn.path <> "/api/" <> dsn.project_id <> "/envelope/"
}

fn non_empty(s: String, error: DsnError) -> Result(String, DsnError) {
  case s {
    "" -> Error(error)
    _ -> Ok(s)
  }
}

fn join(segments: List(String)) -> String {
  case segments {
    [] -> ""
    _ -> "/" <> string.join(segments, "/")
  }
}

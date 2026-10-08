//// One request in flight at a time, sent from a helper process so a slow or
//// hung service never blocks its owner. For senders that report to an
//// outside service (`gloss_sentry`, `gloss_otel`).
////
//// The owner monitors the helper: its result arrives as a message made by
//// `posted`, and if it dies first the owner gets a `process.Down`, which
//// `down` recognises.

import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/option.{type Option, None, Some}

pub opaque type Poster {
  Poster(in_flight: Option(#(Pid, Monitor)))
}

pub fn new() -> Poster {
  Poster(None)
}

/// Send `request` with `send` from a helper process. Its result arrives at
/// `inbox` as `posted(result)`.
pub fn post(
  poster: Poster,
  inbox: Subject(message),
  send: fn(request) -> result,
  request: request,
  posted: fn(result) -> message,
) -> Poster {
  let _ = poster
  let pid =
    process.spawn_unlinked(fn() { process.send(inbox, posted(send(request))) })
  Poster(Some(#(pid, process.monitor(pid))))
}

/// The result arrived: stop watching the helper.
pub fn settled(poster: Poster) -> Poster {
  case poster.in_flight {
    Some(#(_, monitor)) -> process.demonitor_process(monitor)
    None -> Nil
  }
  Poster(None)
}

/// Whether `down` reports the in-flight helper dying, and the poster after
/// it. Other monitors' messages leave it unchanged.
pub fn down(poster: Poster, down: process.Down) -> #(Poster, Bool) {
  case poster.in_flight, down {
    Some(#(pid, _)), process.ProcessDown(pid: dead, ..) if pid == dead -> #(
      Poster(None),
      True,
    )
    _, _ -> #(poster, False)
  }
}

//// Operating-system signals that ask the application to stop.
////
//// By default the BEAM stops the node as soon as it receives SIGTERM, which
//// cuts off in-flight work. Once anything has subscribed here, SIGTERM and
//// SIGHUP are delivered to the subscribers instead, and the application
//// decides how to stop:
////
//// ```gleam
//// let assert Ok(srv) = web.start(config, ctx)
//// signal.wait_for_terminate()
//// let _ = server.shutdown(srv)
//// ```
////
//// If every subscriber has exited when SIGTERM arrives, the node stops as
//// it would have by default.
////
//// SIGINT (Ctrl-C) cannot be caught by the BEAM: it opens the break menu
//// or stops the node immediately. Send SIGTERM (`kill -TERM`, `docker
//// stop`, systemd, Kubernetes) to stop gracefully.

import gleam/erlang/process.{type Subject}

pub type Signal {
  /// SIGTERM: stop.
  Terminate
  /// SIGHUP: the controlling terminal went away, or a reload was requested.
  Hangup
}

/// Deliver SIGTERM and SIGHUP to the returned subject, owned by the calling
/// process. Subscribing again from any process adds another subscriber.
pub fn subscribe() -> Subject(Signal) {
  let subject = process.new_subject()
  install(subject)
  subject
}

/// Block the calling process until SIGTERM arrives. SIGHUP is ignored.
pub fn wait_for_terminate() -> Nil {
  wait(subscribe())
}

fn wait(subject: Subject(Signal)) -> Nil {
  case process.receive_forever(subject) {
    Terminate -> Nil
    Hangup -> wait(subject)
  }
}

@external(erlang, "gloss@signal_ffi", "subscribe")
fn install(subject: Subject(Signal)) -> Nil

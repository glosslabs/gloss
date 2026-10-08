//// Process crashes, as the OTP logger handler in `gloss_sentry_crash_ffi`
//// reports them.

import gleam/list
import gloss/meta.{type Meta}
import gloss/sentry/internal/envelope

pub type Crash {
  Crash(
    type_: String,
    value: String,
    /// Module, function/arity, file, line; oldest call first.
    frames: List(#(String, String, String, Int)),
    /// The registered name, or else the pid.
    process: String,
    /// `module.function/arity` the process started in, or "".
    initial_call: String,
  )
}

/// An unhandled exception event body and its meta.
pub fn to_event(crash: Crash) -> #(envelope.Body, Meta) {
  let frames =
    list.map(crash.frames, fn(frame) {
      envelope.Frame(
        module: frame.0,
        function: frame.1,
        filename: frame.2,
        line: frame.3,
      )
    })
  let meta = case crash.initial_call {
    "" -> [#("process", meta.String(crash.process))]
    call -> [
      #("process", meta.String(crash.process)),
      #("initial_call", meta.String(call)),
    ]
  }
  #(
    envelope.Exception(
      type_: crash.type_,
      value: crash.value,
      frames:,
      mechanism: "otp_crash",
      handled: False,
    ),
    meta,
  )
}

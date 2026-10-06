import gleam/erlang/process
import gleeunit/should
import gloss/signal

pub fn terminate_is_delivered_to_every_subscriber_test() {
  let first = signal.subscribe()
  let second = signal.subscribe()
  kill("TERM")
  process.receive(first, 2000) |> should.equal(Ok(signal.Terminate))
  process.receive(second, 2000) |> should.equal(Ok(signal.Terminate))
}

pub fn hangup_is_delivered_test() {
  let subject = signal.subscribe()
  kill("HUP")
  process.receive(subject, 2000) |> should.equal(Ok(signal.Hangup))
}

pub fn wait_for_terminate_returns_on_sigterm_test() {
  let done = process.new_subject()
  process.spawn(fn() {
    signal.wait_for_terminate()
    process.send(done, Nil)
  })
  // Give the waiter time to subscribe before signalling.
  process.sleep(50)
  kill("HUP")
  process.receive(done, 100) |> should.equal(Error(Nil))
  kill("TERM")
  process.receive(done, 2000) |> should.equal(Ok(Nil))
}

/// Send a signal to this BEAM's OS process.
@external(erlang, "signal_test_ffi", "kill")
fn kill(signal: String) -> Nil

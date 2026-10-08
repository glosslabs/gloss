import gleam/erlang/atom
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import gloss/store.{type Reply, Unavailable}

type Message {
  Add(amount: Int, reply: Reply(Int))
  Slow(ms: Int, reply: Reply(Nil))
  Fail(reply: Reply(Nil))
}

fn counter() -> store.Builder(Message) {
  store.serial(0, fn(total, message) {
    case message {
      Add(amount:, reply:) -> {
        let total = total + amount
        process.send(reply, Ok(total))
        total
      }
      Slow(ms:, reply:) -> {
        process.sleep(ms)
        process.send(reply, Ok(Nil))
        total
      }
      Fail(reply:) -> {
        process.send(reply, Error(Unavailable("disk on fire")))
        total
      }
    }
  })
}

/// Answers in whichever process runs it, reporting that process's pid.
fn inline() -> store.Store(Message) {
  store.inline(fn(message) {
    case message {
      Slow(ms:, reply:) -> {
        process.sleep(ms)
        process.send(reply, Ok(Nil))
      }
      Add(amount:, reply:) -> process.send(reply, Ok(amount))
      Fail(reply:) -> process.send(reply, Error(Unavailable("down")))
    }
  })
}

pub fn a_serial_store_keeps_state_test() {
  let assert Ok(counter) = store.start(counter())
  assert store.call(counter, Add(2, _)) == 2
  assert store.call(counter, Add(3, _)) == 5
}

pub fn an_inline_store_answers_in_the_calling_process_test() {
  let answered_by = process.new_subject()
  let here =
    store.inline(fn(message) {
      case message {
        Add(amount:, reply:) -> {
          process.send(answered_by, process.self())
          process.send(reply, Ok(amount))
        }
        _ -> Nil
      }
    })
  assert store.call(here, Add(3, _)) == 3
  assert process.receive(answered_by, 0) == Ok(process.self())
}

pub fn an_inline_store_runs_concurrently_for_concurrent_callers_test() {
  let inline = inline()
  let done = process.new_subject()
  let started = monotonic_ms()
  process.spawn(fn() { process.send(done, store.call(inline, Slow(200, _))) })
  process.spawn(fn() { process.send(done, store.call(inline, Slow(200, _))) })
  let assert Ok(Nil) = process.receive(done, 1000)
  let assert Ok(Nil) = process.receive(done, 1000)
  // One after the other would take 400ms.
  assert monotonic_ms() - started < 350
}

pub fn an_inline_store_may_answer_from_another_process_test() {
  let forwarding =
    store.inline(fn(message) {
      process.spawn(fn() {
        case message {
          Add(amount:, reply:) -> process.send(reply, Ok(amount * 2))
          _ -> Nil
        }
      })
      Nil
    })
  assert store.call(forwarding, Add(5, _)) == 10
}

pub fn unavailable_inline_storage_panics_the_caller_test() {
  let assert Error(_) = rescue(fn() { store.call(inline(), Fail) })
}

pub fn unavailable_storage_panics_the_caller_test() {
  let assert Ok(counter) = store.start(counter())
  let assert Error(_) = rescue(fn() { store.call(counter, Fail) })
  // The store itself carries on.
  assert store.call(counter, Add(1, _)) == 1
}

pub fn a_named_store_is_reachable_from_its_name_test() {
  let name = process.new_name("store_test")
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(counter() |> store.named(name) |> store.supervised)
    |> supervisor.start
  assert store.call(store.from_name(name), Add(4, _)) == 4
}

pub fn reply_turns_errors_into_unavailable_test() {
  let reply = process.new_subject()
  store.reply(Ok(1), to: reply)
  store.reply(Error("timed out waiting for a connection"), to: reply)
  assert process.receive(reply, 0) == Ok(Ok(1))
  assert process.receive(reply, 0)
    == Ok(Error(Unavailable("timed out waiting for a connection")))
}

@external(erlang, "gloss@http@server_ffi", "rescue")
fn rescue(work: fn() -> a) -> Result(a, b)

fn monotonic_ms() -> Int {
  monotonic_time(atom.create("millisecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

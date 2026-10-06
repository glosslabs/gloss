import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import gloss/meta
import gloss/scheduler
import gloss/scheduler/schedule
import gloss/scheduler/task.{Started, Succeeded}
import gloss/tracer
import support.{drain, utc}

fn ok_handler() -> Result(Nil, String) {
  Ok(Nil)
}

/// A runner that emits the given events and records the tasks it was given.
fn fake_runner(
  events: List(task.Event),
  record: process.Subject(List(task.Task)),
) -> scheduler.Runner {
  fn(tasks, emit) {
    process.send(record, tasks)
    list.each(events, emit)
    Ok(fn() { Nil })
  }
}

pub fn dispatch_order_is_typed_then_any_then_tracer_test() {
  let seen = process.new_subject()
  let record = process.new_subject()
  let started = Started("t", utc(2026, 10, 6, 12, 0))
  let succeeded = Succeeded("t", utc(2026, 10, 6, 12, 0), duration.seconds(1))
  let tel =
    tracer.new()
    |> tracer.handle(fn(e) { process.send(seen, "tracer:" <> e.name) })

  let assert Ok(_stop) =
    scheduler.new()
    |> scheduler.runner(fake_runner(
      [task.TaskStarted(started), task.TaskSucceeded(succeeded)],
      record,
    ))
    |> scheduler.tracer(tel)
    |> scheduler.on_event(fn(_) { process.send(seen, "any") })
    |> scheduler.on_started(fn(e) { process.send(seen, "started:" <> e.task) })
    |> scheduler.on_started(fn(_) { process.send(seen, "started-2") })
    |> scheduler.on_succeeded(fn(_) { process.send(seen, "succeeded") })
    |> scheduler.on_failed(fn(_) { process.send(seen, "failed") })
    |> scheduler.start([
      task.add(task.task("t", schedule.every(duration.seconds(1)), ok_handler)),
    ])

  drain(seen)
  |> should.equal([
    "started:t", "started-2", "any", "tracer:task.started", "succeeded", "any",
    "tracer:task.succeeded",
  ])
}

const fixed = tracer.SpanContext(trace_id: "t", span_id: "s")

pub fn to_trace_test() {
  let at = utc(2026, 10, 6, 12, 0)
  let took = duration.seconds(2)
  let meta = [#("task", meta.String("t"))]
  let failed =
    tracer.Span(
      source: "gloss.scheduler",
      name: "task.failed",
      at: timestamp.subtract(at, took),
      meta:,
      duration: took,
      error: Some("boom"),
      trace: fixed,
      parent_span_id: None,
    )
  // Each run is a new trace, with random ids: compare the rest.
  let trace = fn(event) {
    case event {
      tracer.Span(trace:, ..) -> {
        string.length(trace.trace_id) |> should.equal(32)
        tracer.Span(..event, trace: fixed)
      }
      _ -> event
    }
  }
  scheduler.to_trace(task.TaskFailed(task.Failed("t", at, took, "boom")))
  |> trace
  |> should.equal(failed)
  scheduler.to_trace(task.TaskCrashed(task.Crashed("t", at, took, "exit")))
  |> trace
  |> should.equal(
    tracer.Span(..failed, name: "task.crashed", error: Some("exit")),
  )
  scheduler.to_trace(task.TaskSucceeded(task.Succeeded("t", at, took)))
  |> trace
  |> should.equal(tracer.Span(..failed, name: "task.succeeded", error: None))

  let started =
    tracer.Point(
      source: "gloss.scheduler",
      name: "task.started",
      at:,
      meta:,
      level: tracer.Info,
      trace: None,
    )
  scheduler.to_trace(task.TaskStarted(task.Started("t", at)))
  |> should.equal(started)
  scheduler.to_trace(task.TaskSkipped(task.Skipped("t", at)))
  |> should.equal(
    tracer.Point(..started, name: "task.skipped", level: tracer.Warning),
  )
}

pub fn start_drops_holes_and_applies_wrap_test() {
  let record = process.new_subject()
  let calls = process.new_subject()
  let tasks =
    [
      task.add(task.task("a", schedule.every(duration.seconds(1)), ok_handler)),
      task.add_when(
        False,
        task.task("b", schedule.every(duration.seconds(1)), ok_handler),
      ),
    ]
    |> task.wrap(fn(t, next) {
      process.send(calls, t.name)
      next()
    })
  let assert Ok(_) =
    scheduler.new()
    |> scheduler.runner(fake_runner([], record))
    |> scheduler.start(tasks)
  let assert Ok([only]) = process.receive(record, 100)
  only.name |> should.equal("a")
  only.handler() |> should.equal(Ok(Nil))
  drain(calls) |> should.equal(["a"])
}

pub fn start_rejects_duplicates_and_invalid_schedules_test() {
  let t = task.task("same", schedule.every(duration.seconds(1)), ok_handler)
  scheduler.new()
  |> scheduler.start([task.add(t), task.add(t)])
  |> should.equal(Error(scheduler.DuplicateTask("same")))

  scheduler.new()
  |> scheduler.start([
    task.add(task.task("z", schedule.every(duration.seconds(0)), ok_handler)),
  ])
  |> should.equal(
    Error(scheduler.InvalidSchedule("z", "interval must be positive")),
  )
}

type Seen {
  SawStarted(String)
  SawSucceeded(String)
  SawFailed(String, String)
  SawCrashed(String)
  SawSkipped(String)
}

fn observed(seen: process.Subject(Seen)) -> scheduler.Scheduler {
  scheduler.new()
  |> scheduler.on_started(fn(e) { process.send(seen, SawStarted(e.task)) })
  |> scheduler.on_succeeded(fn(e) { process.send(seen, SawSucceeded(e.task)) })
  |> scheduler.on_failed(fn(e) {
    process.send(seen, SawFailed(e.task, e.error))
  })
  |> scheduler.on_crashed(fn(e) { process.send(seen, SawCrashed(e.task)) })
  |> scheduler.on_skipped(fn(e) { process.send(seen, SawSkipped(e.task)) })
}

pub fn runs_tasks_and_stops_test() {
  let seen = process.new_subject()
  let assert Ok(stop) =
    observed(seen)
    |> scheduler.start([
      task.add(task.task(
        "beat",
        schedule.every(duration.milliseconds(20)),
        ok_handler,
      )),
    ])
  process.receive(seen, 500) |> should.equal(Ok(SawStarted("beat")))
  process.receive(seen, 500) |> should.equal(Ok(SawSucceeded("beat")))

  stop()
  stop()
  process.sleep(60)
  drain(seen)
  process.receive(seen, 80) |> should.equal(Error(Nil))
}

pub fn reports_failures_and_crashes_and_keeps_going_test() {
  let seen = process.new_subject()
  let assert Ok(stop) =
    observed(seen)
    |> scheduler.start([
      task.add(
        task.task("bad", schedule.after(duration.milliseconds(10)), fn() {
          Error("nope")
        }),
      ),
      task.add(
        task.task("boom", schedule.after(duration.milliseconds(10)), fn() {
          panic as "boom"
        }),
      ),
      task.add(task.task(
        "beat",
        schedule.every(duration.milliseconds(40)),
        ok_handler,
      )),
    ])
  process.sleep(150)
  stop()
  let events = drain(seen)
  list.contains(events, SawFailed("bad", "nope")) |> should.be_true
  list.contains(events, SawCrashed("boom")) |> should.be_true
  // The crash did not take the scheduler down: the heartbeat ran afterwards.
  let after_crash =
    events |> list.drop_while(fn(e) { e != SawCrashed("boom") }) |> list.drop(1)
  list.contains(after_crash, SawSucceeded("beat")) |> should.be_true
}

pub fn skips_overlapping_runs_test() {
  let seen = process.new_subject()
  let slow = fn() {
    process.sleep(120)
    Ok(Nil)
  }
  let assert Ok(stop) =
    observed(seen)
    |> scheduler.start([
      task.add(task.task(
        "slow",
        schedule.every(duration.milliseconds(30)),
        slow,
      )),
    ])
  process.sleep(100)
  stop()
  let events = drain(seen)
  list.count(events, fn(e) { e == SawStarted("slow") }) |> should.equal(1)
  { list.count(events, fn(e) { e == SawSkipped("slow") }) >= 1 }
  |> should.be_true
}

pub fn one_off_runs_once_test() {
  let seen = process.new_subject()
  let assert Ok(stop) =
    observed(seen)
    |> scheduler.start([
      task.add(task.task(
        "once",
        schedule.after(duration.milliseconds(10)),
        ok_handler,
      )),
    ])
  process.sleep(100)
  stop()
  drain(seen) |> should.equal([SawStarted("once"), SawSucceeded("once")])
}

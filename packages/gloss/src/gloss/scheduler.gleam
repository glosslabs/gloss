//// Run tasks on a schedule, on this machine, in this application.
////
//// Build a `Scheduler`, then start it with the application's tasks:
////
//// ```gleam
//// let assert Ok(stop) =
////   scheduler.new()
////   |> scheduler.tracer(ctx.tracer)
////   |> scheduler.on_failed(fn(failed) { alert(failed.task, failed.error) })
////   |> scheduler.start(app_schedule.tasks(ctx))
//// // ... later ...
//// stop()
//// ```
////
//// The built-in runner is one Erlang process that sleeps until the next
//// task is due and runs each due task in its own process. Nothing is
//// persisted: runs missed while the application was down are not caught up,
//// and `stop` leaves runs already in flight to finish on their own.
////
//// Every run is reported to the typed `on_*` callbacks and as a
//// `tracer.Event` to the attached `Tracer`. Both run inline in the
//// scheduler process and follow the handler contract in `gloss/tracer`:
//// cheap, and never panicking.

import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import gloss/internal/scheduler_engine as engine
import gloss/meta
import gloss/scheduler/task.{
  type Crashed, type Event, type Failed, type Skipped, type Started,
  type Succeeded, type Task, type Tasks, TaskCrashed, TaskFailed, TaskSkipped,
  TaskStarted, TaskSucceeded,
}
import gloss/tracer.{type Tracer}

/// Configuration for running tasks. Build one with `new` and the `on_*`,
/// `tracer` and `runner` functions, then `start` it.
pub opaque type Scheduler {
  Scheduler(runner: Runner, tracer: Tracer, hooks: Hooks)
}

type Hooks {
  Hooks(
    started: List(fn(Started) -> Nil),
    succeeded: List(fn(Succeeded) -> Nil),
    failed: List(fn(Failed) -> Nil),
    crashed: List(fn(Crashed) -> Nil),
    skipped: List(fn(Skipped) -> Nil),
    any: List(fn(Event) -> Nil),
  )
}

/// Something that can drive a set of tasks. It is given every task to run
/// and a function to report events through, and returns a `Stopper`. The
/// built-in one is `erlang_runner`; supply another with `runner`, e.g. one
/// that records what it was given in tests.
pub type Runner =
  fn(List(Task), fn(Event) -> Nil) -> Result(Stopper, Error)

/// Stops a started scheduler. Calling it more than once is harmless.
pub type Stopper =
  fn() -> Nil

pub type Error {
  /// The runner could not start.
  Unavailable(reason: String)
  /// Two tasks share a name.
  DuplicateTask(name: String)
  /// A task's schedule can never fire, e.g. a zero interval or a cron
  /// expression with no match in the next five years.
  InvalidSchedule(name: String, reason: String)
}

/// A scheduler on the built-in runner with no tracer and no callbacks.
pub fn new() -> Scheduler {
  Scheduler(
    runner: erlang_runner(),
    tracer: tracer.new(),
    hooks: Hooks([], [], [], [], [], []),
  )
}

/// Use a different runner.
pub fn runner(scheduler: Scheduler, runner: Runner) -> Scheduler {
  Scheduler(..scheduler, runner:)
}

/// Report every event to this tracer as well, converted with `to_trace`.
pub fn tracer(scheduler: Scheduler, tracer: Tracer) -> Scheduler {
  Scheduler(..scheduler, tracer:)
}

/// Called when a run starts.
pub fn on_started(scheduler: Scheduler, f: fn(Started) -> Nil) -> Scheduler {
  let hooks = scheduler.hooks
  Scheduler(
    ..scheduler,
    hooks: Hooks(..hooks, started: list.append(hooks.started, [f])),
  )
}

/// Called when a run returns `Ok`.
pub fn on_succeeded(
  scheduler: Scheduler,
  f: fn(Succeeded) -> Nil,
) -> Scheduler {
  let hooks = scheduler.hooks
  Scheduler(
    ..scheduler,
    hooks: Hooks(..hooks, succeeded: list.append(hooks.succeeded, [f])),
  )
}

/// Called when a run returns `Error`.
pub fn on_failed(scheduler: Scheduler, f: fn(Failed) -> Nil) -> Scheduler {
  let hooks = scheduler.hooks
  Scheduler(
    ..scheduler,
    hooks: Hooks(..hooks, failed: list.append(hooks.failed, [f])),
  )
}

/// Called when a run's process crashes.
pub fn on_crashed(scheduler: Scheduler, f: fn(Crashed) -> Nil) -> Scheduler {
  let hooks = scheduler.hooks
  Scheduler(
    ..scheduler,
    hooks: Hooks(..hooks, crashed: list.append(hooks.crashed, [f])),
  )
}

/// Called when a due run is skipped because the previous one is still going.
pub fn on_skipped(scheduler: Scheduler, f: fn(Skipped) -> Nil) -> Scheduler {
  let hooks = scheduler.hooks
  Scheduler(
    ..scheduler,
    hooks: Hooks(..hooks, skipped: list.append(hooks.skipped, [f])),
  )
}

/// Called with every event, after the event's own callbacks.
pub fn on_event(scheduler: Scheduler, f: fn(Event) -> Nil) -> Scheduler {
  let hooks = scheduler.hooks
  Scheduler(
    ..scheduler,
    hooks: Hooks(..hooks, any: list.append(hooks.any, [f])),
  )
}

/// Start the tasks. Entries switched off by `task.add_when` are dropped
/// here, before the runner sees them.
pub fn start(scheduler: Scheduler, tasks: Tasks) -> Result(Stopper, Error) {
  let tasks = option.values(tasks)
  use _ <- result.try(no_duplicates(tasks))
  scheduler.runner(tasks, dispatcher(scheduler))
}

fn no_duplicates(tasks: List(Task)) -> Result(Nil, Error) {
  let names = list.map(tasks, fn(t) { t.name })
  case list.find(names, fn(n) { list.count(names, fn(m) { m == n }) > 1 }) {
    Ok(name) -> Error(DuplicateTask(name))
    Error(Nil) -> Ok(Nil)
  }
}

/// Typed callbacks first, then `on_event` callbacks, then the tracer.
fn dispatcher(scheduler: Scheduler) -> fn(Event) -> Nil {
  let hooks = scheduler.hooks
  fn(event) {
    case event {
      TaskStarted(e) -> list.each(hooks.started, fn(f) { f(e) })
      TaskSucceeded(e) -> list.each(hooks.succeeded, fn(f) { f(e) })
      TaskFailed(e) -> list.each(hooks.failed, fn(f) { f(e) })
      TaskCrashed(e) -> list.each(hooks.crashed, fn(f) { f(e) })
      TaskSkipped(e) -> list.each(hooks.skipped, fn(f) { f(e) })
    }
    list.each(hooks.any, fn(f) { f(event) })
    tracer.emit(scheduler.tracer, fn() { to_trace(event) })
  }
}

/// The trace form of a scheduler event, source `gloss.scheduler`, with the
/// task name in the `task` meta entry. A run that started or was skipped is
/// a `Point` (`task.started` at `Info`, `task.skipped` at `Warning`). A run
/// that finished is a `Span` starting when the run did: `task.succeeded`,
/// `task.failed` with the returned error, or `task.crashed` with the exit
/// reason.
pub fn to_trace(event: Event) -> tracer.Event {
  let source = "gloss.scheduler"
  let task_meta = fn(task) { [#("task", meta.String(task))] }
  let point = fn(name, task, at, level) {
    tracer.Point(
      source:,
      name:,
      at:,
      meta: task_meta(task),
      level:,
      trace: None,
    )
  }
  let span = fn(name, task, at, took, error) {
    tracer.Span(
      source:,
      name:,
      at: timestamp.subtract(at, took),
      meta: task_meta(task),
      duration: took,
      error:,
      trace: tracer.root(),
      parent_span_id: None,
    )
  }
  case event {
    TaskStarted(e) -> point("task.started", e.task, e.at, tracer.Info)
    TaskSkipped(e) -> point("task.skipped", e.task, e.at, tracer.Warning)
    TaskSucceeded(e) -> span("task.succeeded", e.task, e.at, e.took, None)
    TaskFailed(e) -> span("task.failed", e.task, e.at, e.took, Some(e.error))
    TaskCrashed(e) -> span("task.crashed", e.task, e.at, e.took, Some(e.reason))
  }
}

type Control {
  Stop
}

type Report {
  Finished(name: String, pid: Pid, result: Result(Nil, String))
}

type Message {
  Controlled(Control)
  Reported(Report)
  Down(process.Down)
}

type Shell {
  Shell(
    selector: Selector(Message),
    inbox: Subject(Report),
    emit: fn(Event) -> Nil,
  )
}

/// The built-in runner: one Erlang process that sleeps until the next task
/// is due and runs each due task in its own unlinked process. Exposed so it
/// can be wrapped by a custom `Runner`.
pub fn erlang_runner() -> Runner {
  fn(tasks, emit) {
    let now = timestamp.system_time()
    use state <- result.try(
      engine.init(tasks, now)
      |> result.map_error(fn(i) { InvalidSchedule(i.task, i.reason) }),
    )
    let handshake = process.new_subject()
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      let inbox = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select_map(control, Controlled)
        |> process.select_map(inbox, Reported)
        |> process.select_monitors(Down)
      process.send(handshake, control)
      loop(Shell(selector:, inbox:, emit:), state)
    })
    case process.receive(handshake, 1000) {
      Ok(control) -> Ok(fn() { process.send(control, Stop) })
      Error(Nil) -> Error(Unavailable("scheduler process did not start"))
    }
  }
}

fn loop(shell: Shell, state: engine.State) -> Nil {
  let wait = engine.timeout_ms(state, timestamp.system_time())
  case process.selector_receive(shell.selector, wait) {
    Ok(Controlled(Stop)) -> Nil
    Error(Nil) -> {
      let now = timestamp.system_time()
      engine.tick(state, now) |> perform(shell, now) |> loop(shell, _)
    }
    Ok(Reported(Finished(name:, pid:, result:))) -> {
      let now = timestamp.system_time()
      engine.finished(state, name, pid, result, now)
      |> perform(shell, now)
      |> loop(shell, _)
    }
    Ok(Down(process.ProcessDown(pid:, reason:, ..))) -> {
      let now = timestamp.system_time()
      engine.down(state, pid, string.inspect(reason), now)
      |> perform(shell, now)
      |> loop(shell, _)
    }
    Ok(Down(process.PortDown(..))) -> loop(shell, state)
  }
}

fn perform(
  transition: #(engine.State, List(engine.Action)),
  shell: Shell,
  now: Timestamp,
) -> engine.State {
  let #(state, actions) = transition
  list.fold(actions, state, fn(state, action) {
    case action {
      engine.Spawn(task) -> {
        let inbox = shell.inbox
        let pid =
          process.spawn_unlinked(fn() {
            let result = task.handler()
            process.send(inbox, Finished(task.name, process.self(), result))
          })
        let monitor = process.monitor(pid)
        engine.attach(state, task.name, pid, monitor, now)
      }
      engine.Emit(event) -> {
        shell.emit(event)
        state
      }
      engine.Demonitor(monitor) -> {
        process.demonitor_process(monitor)
        state
      }
    }
  })
}

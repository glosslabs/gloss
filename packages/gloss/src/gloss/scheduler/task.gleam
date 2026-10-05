//// Tasks: named units of work with a `Schedule` saying when they run, and
//// the events a scheduler emits about their runs.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import gloss/scheduler/schedule.{type Schedule}

/// A unit of scheduled work. Build one with `task`.
///
/// `handler` runs in its own process, so a crash is contained and will not
/// take down the scheduler or other tasks. A handler that returns `Ok` has
/// succeeded, one that returns `Error` has failed, and one that crashes is
/// reported as crashed.
pub type Task {
  Task(
    name: String,
    schedule: Schedule,
    handler: TaskHandler,
    /// What to do when the task is due while a previous run is still going.
    overlap: Overlap,
  )
}

pub type TaskHandler =
  fn() -> Result(Nil, String)

pub type Overlap {
  /// Skip this run and report it as skipped. The default.
  Skip
  /// Start another run alongside the one in flight.
  Allow
}

/// A task that skips a run while the previous one is still going.
pub fn task(name: String, schedule: Schedule, handler: TaskHandler) -> Task {
  Task(name:, schedule:, handler:, overlap: Skip)
}

/// Let runs of this task overlap.
pub fn allow_overlap(task: Task) -> Task {
  Task(..task, overlap: Allow)
}

/// The application's task declarations. Each entry is either a task or a
/// hole left by a condition that was false, so a feature's tasks can be
/// declared in place and switched off without restructuring the list:
///
/// ```gleam
/// pub fn tasks(ctx: AppContext) -> task.Tasks {
///   [
///     task.add(task.task("healthcheck", schedule.every(duration.seconds(30)), healthcheck)),
///     task.add_when(
///       ctx.nightly_cleanup,
///       task.task("cleanup", schedule.cron(cron.every_minute() |> cron.hour(3) |> cron.minute(0)), cleanup),
///     ),
///   ]
/// }
/// ```
pub type Tasks =
  List(Option(Task))

/// Declare a task that always runs.
pub fn add(task: Task) -> Option(Task) {
  Some(task)
}

/// Declare a task that is only scheduled when `condition` is true.
pub fn add_when(condition: Bool, task: Task) -> Option(Task) {
  case condition {
    True -> Some(task)
    False -> None
  }
}

/// Wrap every task's handler with middleware, e.g. tracing or error
/// reporting. `with` receives the task and its original handler.
pub fn wrap(
  tasks: Tasks,
  with: fn(Task, TaskHandler) -> Result(Nil, String),
) -> Tasks {
  list.map(tasks, fn(entry) {
    option.map(entry, fn(t) { Task(..t, handler: fn() { with(t, t.handler) }) })
  })
}

/// A run began. `at` is when it was due and started.
pub type Started {
  Started(task: String, at: Timestamp)
}

/// A run returned `Ok`.
pub type Succeeded {
  Succeeded(task: String, at: Timestamp, took: Duration)
}

/// A run returned `Error`.
pub type Failed {
  Failed(task: String, at: Timestamp, took: Duration, error: String)
}

/// A run's process exited abnormally before returning.
pub type Crashed {
  Crashed(task: String, at: Timestamp, took: Duration, reason: String)
}

/// A run was due but the previous run was still going and the task's
/// overlap policy is `Skip`.
pub type Skipped {
  Skipped(task: String, at: Timestamp)
}

/// Everything a scheduler reports about task runs.
pub type Event {
  TaskStarted(Started)
  TaskSucceeded(Succeeded)
  TaskFailed(Failed)
  TaskCrashed(Crashed)
  TaskSkipped(Skipped)
}

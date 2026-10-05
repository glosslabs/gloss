//// The scheduler's state machine, kept pure so it can be tested with fixed
//// timestamps. The process shell in `gloss/scheduler` feeds it the current
//// time and the messages it receives, and performs the `Action`s it returns.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Gt, Lt}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import gloss/scheduler/schedule
import gloss/scheduler/task.{
  type Event, type Task, Crashed, Failed, Skip, Skipped, Started, Succeeded,
  TaskCrashed, TaskFailed, TaskSkipped, TaskStarted, TaskSucceeded,
}

pub opaque type State {
  State(entries: Dict(String, Entry), started: Timestamp)
}

type Entry {
  Entry(task: Task, next: Option(Timestamp), running: List(Run))
}

type Run {
  Run(pid: Pid, monitor: Monitor, started_at: Timestamp)
}

/// What the shell must do after a transition, in order.
pub type Action {
  /// Start the task's handler in a new process, then `attach` it.
  Spawn(task: Task)
  /// Report the event.
  Emit(event: Event)
  /// Stop watching a run that reported its result.
  Demonitor(monitor: Monitor)
}

/// A task whose schedule can never fire.
pub type Invalid {
  Invalid(task: String, reason: String)
}

/// The longest wait `timeout_ms` returns: the Erlang receive timeout limit.
const max_timeout_ms = 4_294_967_295

/// Validate every task and compute its first run.
pub fn init(tasks: List(Task), now: Timestamp) -> Result(State, Invalid) {
  let state = State(entries: dict.new(), started: now)
  list.try_fold(tasks, state, fn(state, task) {
    case first_run(task, now) {
      Ok(next) -> {
        let entry = Entry(task:, next:, running: [])
        Ok(
          State(..state, entries: dict.insert(state.entries, task.name, entry)),
        )
      }
      Error(reason) -> Error(Invalid(task.name, reason))
    }
  })
}

fn first_run(task: Task, now: Timestamp) -> Result(Option(Timestamp), String) {
  case task.schedule {
    schedule.Every(interval) ->
      case positive(interval) {
        True -> Ok(schedule.next_run(task.schedule, after: now, started: now))
        False -> Error("interval must be positive")
      }
    schedule.After(delay) ->
      case positive(delay) {
        True -> Ok(schedule.next_run(task.schedule, after: now, started: now))
        False -> Error("delay must be positive")
      }
    // A one-off whose time has passed runs once, straight away.
    schedule.At(when) ->
      case timestamp.compare(when, now) {
        Gt -> Ok(Some(when))
        _ -> Ok(Some(now))
      }
    schedule.Cron(..) ->
      case schedule.next_run(task.schedule, after: now, started: now) {
        Some(next) -> Ok(Some(next))
        None -> Error("cron expression never matches")
      }
  }
}

// `duration.compare` orders by magnitude, so look at the parts directly.
fn positive(d: duration.Duration) -> Bool {
  let #(seconds, nanoseconds) = duration.to_seconds_and_nanoseconds(d)
  seconds > 0 || { seconds == 0 && nanoseconds > 0 }
}

/// Run everything that is due at `now`.
pub fn tick(state: State, now: Timestamp) -> #(State, List(Action)) {
  state.entries
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.fold(#(state, []), fn(acc, pair) {
    let #(state, actions) = acc
    let #(name, entry) = pair
    case entry.next {
      Some(due) ->
        case timestamp.compare(due, now) {
          Gt -> acc
          _ -> {
            let actions = case entry.running, entry.task.overlap {
              [_, ..], Skip -> [
                Emit(TaskSkipped(Skipped(task: name, at: now))),
                ..actions
              ]
              _, _ -> [
                Emit(TaskStarted(Started(task: name, at: now))),
                Spawn(entry.task),
                ..actions
              ]
            }
            let next =
              schedule.next_run(
                entry.task.schedule,
                after: now,
                started: state.started,
              )
            #(put(state, Entry(..entry, next:)), actions)
          }
        }
      None -> acc
    }
  })
  |> reversed
}

/// Record a spawned run so its result or crash can be attributed.
pub fn attach(
  state: State,
  name: String,
  pid: Pid,
  monitor: Monitor,
  started_at: Timestamp,
) -> State {
  case dict.get(state.entries, name) {
    Ok(entry) -> {
      let run = Run(pid:, monitor:, started_at:)
      put(state, Entry(..entry, running: [run, ..entry.running]))
    }
    Error(Nil) -> state
  }
}

/// A run's process reported its result.
pub fn finished(
  state: State,
  name: String,
  pid: Pid,
  result: Result(Nil, String),
  now: Timestamp,
) -> #(State, List(Action)) {
  case take_run(state, name, pid) {
    Error(Nil) -> #(state, [])
    Ok(#(state, run)) -> {
      let took = timestamp.difference(run.started_at, now)
      let event = case result {
        Ok(Nil) -> TaskSucceeded(Succeeded(task: name, at: now, took:))
        Error(error) -> TaskFailed(Failed(task: name, at: now, took:, error:))
      }
      #(state, [Demonitor(run.monitor), Emit(event)])
    }
  }
}

/// A run's process exited. Ignored when the run already reported its
/// result, or the pid is not a run at all.
pub fn down(
  state: State,
  pid: Pid,
  reason: String,
  now: Timestamp,
) -> #(State, List(Action)) {
  let found =
    dict.to_list(state.entries)
    |> list.find_map(fn(pair) {
      case list.any({ pair.1 }.running, fn(run) { run.pid == pid }) {
        True -> Ok(pair.0)
        False -> Error(Nil)
      }
    })
  case found {
    Error(Nil) -> #(state, [])
    Ok(name) ->
      case take_run(state, name, pid) {
        Error(Nil) -> #(state, [])
        Ok(#(state, run)) -> {
          let took = timestamp.difference(run.started_at, now)
          #(state, [
            Emit(TaskCrashed(Crashed(task: name, at: now, took:, reason:))),
          ])
        }
      }
  }
}

/// Milliseconds until the next run is due, clamped to the receive limit.
pub fn timeout_ms(state: State, now: Timestamp) -> Int {
  let soonest =
    dict.values(state.entries)
    |> list.filter_map(fn(entry) { option.to_result(entry.next, Nil) })
    |> list.reduce(fn(a, b) {
      case timestamp.compare(a, b) {
        Lt -> a
        _ -> b
      }
    })
  case soonest {
    Error(Nil) -> max_timeout_ms
    Ok(next) -> {
      let ms = duration.to_milliseconds(timestamp.difference(now, next))
      case ms < 0, ms > max_timeout_ms {
        True, _ -> 0
        _, True -> max_timeout_ms
        _, _ -> ms
      }
    }
  }
}

/// Whether any task can still run or is running.
pub fn is_idle(state: State) -> Bool {
  dict.is_empty(state.entries)
}

fn put(state: State, entry: Entry) -> State {
  State(..state, entries: dict.insert(state.entries, entry.task.name, entry))
}

/// Store an entry, dropping it instead once it can neither run again nor is
/// running. Only called once a run has ended: between `tick` and `attach`
/// an entry has no run yet, and must survive.
fn prune(state: State, entry: Entry) -> State {
  case entry.next, entry.running {
    None, [] ->
      State(..state, entries: dict.delete(state.entries, entry.task.name))
    _, _ -> put(state, entry)
  }
}

fn take_run(
  state: State,
  name: String,
  pid: Pid,
) -> Result(#(State, Run), Nil) {
  case dict.get(state.entries, name) {
    Error(Nil) -> Error(Nil)
    Ok(entry) ->
      case list.find(entry.running, fn(run) { run.pid == pid }) {
        Error(Nil) -> Error(Nil)
        Ok(run) -> {
          let running = list.filter(entry.running, fn(r) { r.pid != pid })
          Ok(#(prune(state, Entry(..entry, running:)), run))
        }
      }
  }
}

fn reversed(pair: #(State, List(Action))) -> #(State, List(Action)) {
  #(pair.0, list.reverse(pair.1))
}

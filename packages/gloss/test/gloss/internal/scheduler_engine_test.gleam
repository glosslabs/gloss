import gleam/erlang/process.{type Monitor, type Pid}
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import gloss/internal/scheduler_engine as engine
import gloss/scheduler/cron
import gloss/scheduler/schedule
import gloss/scheduler/task.{Crashed, Failed, Skipped, Started, Succeeded}
import support.{utc}

fn now() {
  utc(2026, 10, 6, 12, 0)
}

fn later(seconds: Int) {
  timestamp.add(now(), duration.seconds(seconds))
}

fn ok_handler() -> Result(Nil, String) {
  Ok(Nil)
}

fn every_ten() -> task.Task {
  task.task("tick", schedule.every(duration.seconds(10)), ok_handler)
}

fn dummy() -> #(Pid, Monitor) {
  let pid = process.spawn_unlinked(fn() { process.sleep_forever() })
  #(pid, process.monitor(pid))
}

pub fn init_rejects_impossible_schedules_test() {
  engine.init(
    [task.task("z", schedule.every(duration.seconds(0)), ok_handler)],
    now(),
  )
  |> should.equal(Error(engine.Invalid("z", "interval must be positive")))
  engine.init(
    [task.task("a", schedule.after(duration.seconds(-1)), ok_handler)],
    now(),
  )
  |> should.equal(Error(engine.Invalid("a", "delay must be positive")))
  let assert Ok(never) = cron.parse("0 0 31 2 *")
  engine.init([task.task("c", schedule.cron(never), ok_handler)], now())
  |> should.equal(Error(engine.Invalid("c", "cron expression never matches")))
}

pub fn tick_runs_due_tasks_only_test() {
  let assert Ok(state) = engine.init([every_ten()], now())
  let #(state, actions) = engine.tick(state, later(9))
  actions |> should.equal([])
  let #(_, actions) = engine.tick(state, later(10))
  actions
  |> should.equal([
    engine.Spawn(every_ten()),
    engine.Emit(task.TaskStarted(Started("tick", later(10)))),
  ])
}

pub fn tick_skips_when_previous_run_in_flight_test() {
  let assert Ok(state) = engine.init([every_ten()], now())
  let #(state, _) = engine.tick(state, later(10))
  let #(pid, monitor) = dummy()
  let state = engine.attach(state, "tick", pid, monitor, later(10))
  let #(_, actions) = engine.tick(state, later(20))
  actions
  |> should.equal([engine.Emit(task.TaskSkipped(Skipped("tick", later(20))))])
}

pub fn tick_overlaps_when_allowed_test() {
  let t = every_ten() |> task.allow_overlap
  let assert Ok(state) = engine.init([t], now())
  let #(state, _) = engine.tick(state, later(10))
  let #(pid, monitor) = dummy()
  let state = engine.attach(state, "tick", pid, monitor, later(10))
  let #(_, actions) = engine.tick(state, later(20))
  actions
  |> should.equal([
    engine.Spawn(t),
    engine.Emit(task.TaskStarted(Started("tick", later(20)))),
  ])
}

pub fn finished_reports_outcome_and_duration_test() {
  let assert Ok(state) = engine.init([every_ten()], now())
  let #(state, _) = engine.tick(state, later(10))
  let #(pid, monitor) = dummy()
  let state = engine.attach(state, "tick", pid, monitor, later(10))

  let #(_, actions) = engine.finished(state, "tick", pid, Ok(Nil), later(12))
  actions
  |> should.equal([
    engine.Demonitor(monitor),
    engine.Emit(
      task.TaskSucceeded(Succeeded("tick", later(12), duration.seconds(2))),
    ),
  ])

  let #(_, actions) =
    engine.finished(state, "tick", pid, Error("boom"), later(13))
  actions
  |> should.equal([
    engine.Demonitor(monitor),
    engine.Emit(
      task.TaskFailed(Failed("tick", later(13), duration.seconds(3), "boom")),
    ),
  ])
}

pub fn finished_for_unknown_run_is_ignored_test() {
  let assert Ok(state) = engine.init([every_ten()], now())
  let #(pid, _) = dummy()
  engine.finished(state, "tick", pid, Ok(Nil), later(1)).1 |> should.equal([])
  engine.finished(state, "nope", pid, Ok(Nil), later(1)).1 |> should.equal([])
}

pub fn down_reports_crash_once_test() {
  let assert Ok(state) = engine.init([every_ten()], now())
  let #(state, _) = engine.tick(state, later(10))
  let #(pid, monitor) = dummy()
  let state = engine.attach(state, "tick", pid, monitor, later(10))

  let #(state, actions) = engine.down(state, pid, "badarg", later(11))
  actions
  |> should.equal([
    engine.Emit(
      task.TaskCrashed(Crashed("tick", later(11), duration.seconds(1), "badarg")),
    ),
  ])
  // Already handled, and a pid that was never a run.
  engine.down(state, pid, "badarg", later(12)).1 |> should.equal([])
  let #(other, _) = dummy()
  engine.down(state, other, "badarg", later(12)).1 |> should.equal([])
}

pub fn one_off_is_dropped_once_its_run_ends_test() {
  let t = task.task("once", schedule.at(later(5)), ok_handler)
  let assert Ok(state) = engine.init([t], now())
  engine.is_idle(state) |> should.be_false
  let #(state, actions) = engine.tick(state, later(5))
  actions
  |> should.equal([
    engine.Spawn(t),
    engine.Emit(task.TaskStarted(Started("once", later(5)))),
  ])
  // Still tracked while its run is in flight, so the result can be reported.
  engine.is_idle(state) |> should.be_false
  let #(pid, monitor) = dummy()
  let state = engine.attach(state, "once", pid, monitor, later(5))
  let #(state, actions) = engine.finished(state, "once", pid, Ok(Nil), later(6))
  actions
  |> should.equal([
    engine.Demonitor(monitor),
    engine.Emit(
      task.TaskSucceeded(Succeeded("once", later(6), duration.seconds(1))),
    ),
  ])
  engine.is_idle(state) |> should.be_true
  engine.timeout_ms(state, later(6)) |> should.equal(4_294_967_295)
}

pub fn past_one_off_runs_straight_away_test() {
  let t = task.task("late", schedule.at(later(-60)), ok_handler)
  let assert Ok(state) = engine.init([t], now())
  engine.timeout_ms(state, now()) |> should.equal(0)
  engine.tick(state, now()).1
  |> should.equal([
    engine.Spawn(t),
    engine.Emit(task.TaskStarted(Started("late", now()))),
  ])
}

pub fn timeout_is_time_until_soonest_task_test() {
  let assert Ok(state) =
    engine.init(
      [
        every_ten(),
        task.task("slow", schedule.every(duration.minutes(5)), ok_handler),
      ],
      now(),
    )
  engine.timeout_ms(state, now()) |> should.equal(10_000)
  engine.timeout_ms(state, later(7)) |> should.equal(3000)
  engine.timeout_ms(state, later(30)) |> should.equal(0)
}

pub fn tick_orders_tasks_by_name_test() {
  let b = task.task("b", schedule.every(duration.seconds(1)), ok_handler)
  let a = task.task("a", schedule.every(duration.seconds(1)), ok_handler)
  let assert Ok(state) = engine.init([b, a], now())
  engine.tick(state, later(1)).1
  |> should.equal([
    engine.Spawn(a),
    engine.Emit(task.TaskStarted(Started("a", later(1)))),
    engine.Spawn(b),
    engine.Emit(task.TaskStarted(Started("b", later(1)))),
  ])
}

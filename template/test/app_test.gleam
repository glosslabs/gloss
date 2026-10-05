import app/context.{AppContext}
import app/schedule
import gleam/list
import gleam/option
import gleeunit
import gleeunit/should
import gloss/logger
import gloss/scheduler/task
import gloss/tracer

pub fn main() -> Nil {
  gleeunit.main()
}

fn context(nightly_cleanup: Bool) -> context.AppContext {
  AppContext(tracer: tracer.new(), log: logger.discard(), nightly_cleanup:)
}

fn names(tasks: task.Tasks) -> List(String) {
  tasks |> option.values |> list.map(fn(task) { task.name })
}

pub fn tasks_test() {
  schedule.tasks(context(True))
  |> names
  |> should.equal(["heartbeat", "warm-up", "nightly-cleanup"])
}

pub fn nightly_cleanup_can_be_switched_off_test() {
  schedule.tasks(context(False))
  |> names
  |> should.equal(["heartbeat", "warm-up"])
}

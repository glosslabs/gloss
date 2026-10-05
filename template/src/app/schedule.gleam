import app/context.{type AppContext}
import gleam/time/duration
import gloss/scheduler/cron
import gloss/scheduler/schedule
import gloss/scheduler/task.{task}

pub fn tasks(ctx: AppContext) -> task.Tasks {
  [
    task.add(task("heartbeat", schedule.every(duration.seconds(30)), heartbeat)),
    task.add(task("warm-up", schedule.after(duration.seconds(5)), warm_up)),
    task.add_when(
      ctx.nightly_cleanup,
      task(
        "nightly-cleanup",
        schedule.cron_in(
          cron.every_minute() |> cron.hour(3) |> cron.minute(0),
          schedule.Local,
        ),
        nightly_cleanup,
      ),
    ),
  ]
}

fn heartbeat() -> Result(Nil, String) {
  Ok(Nil)
}

fn warm_up() -> Result(Nil, String) {
  Ok(Nil)
}

fn nightly_cleanup() -> Result(Nil, String) {
  Ok(Nil)
}

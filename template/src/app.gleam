import app/context.{AppContext}
import app/schedule as app_schedule
import envoy
import gleam/erlang/process
import gleam/httpc
import gleam/result
import gloss/logger
import gloss/meta
import gloss/scheduler
import gloss/tracer
import gloss_sentry

pub fn main() {
  // Add channels with logger.stack, e.g. [logger.stderr(), logger.otp()].
  let log = logger.stderr()

  let tracer =
    tracer.new()
    |> tracer.handle(logger.trace_handler(log))
    |> with_sentry

  let ctx = AppContext(tracer:, log:, nightly_cleanup: True)

  let assert Ok(_) =
    scheduler.new()
    |> scheduler.tracer(ctx.tracer)
    |> scheduler.on_failed(fn(failed) {
      ctx.log.warning("task needs attention", [
        #("task", meta.String(failed.task)),
        #("error", meta.String(failed.error)),
      ])
    })
    |> scheduler.start(app_schedule.tasks(ctx))

  process.sleep_forever()
}

fn with_sentry(tracer: tracer.Tracer) -> tracer.Tracer {
  case envoy.get("SENTRY_DSN") {
    Ok(dsn) -> {
      let assert Ok(sentry) =
        gloss_sentry.config(dsn)
        |> gloss_sentry.environment(
          envoy.get("APP_ENV") |> result.unwrap("production"),
        )
        |> gloss_sentry.start(httpc.send)
      tracer |> tracer.handle(gloss_sentry.handler(sentry))
    }
    Error(Nil) -> tracer
  }
}

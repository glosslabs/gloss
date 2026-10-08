import app/context.{AppContext}
import app/schedule as app_schedule
import envoy
import gleam/erlang/process
import gleam/httpc
import gleam/result
import gloss/logger
import gloss/meta
import gloss/scheduler
import gloss/sentry
import gloss/tracer

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
        sentry.config(dsn)
        |> sentry.environment(
          envoy.get("APP_ENV") |> result.unwrap("production"),
        )
        |> sentry.start(httpc.send)
      tracer |> tracer.handle(sentry.handler(sentry))
    }
    Error(Nil) -> tracer
  }
}

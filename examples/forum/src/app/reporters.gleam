//// Where logs and trace events go: debug and info to stdout, warnings and
//// errors to stderr. Each request's span is one access-log line.

import gloss/logger.{type Logger}
import gloss/tracer.{type Tracer}

pub fn setup() -> #(Logger, Tracer) {
  let log =
    logger.stack([
      logger.stdout() |> logger.max_level(logger.Info),
      logger.stderr() |> logger.min_level(logger.Warning),
    ])
  #(log, tracer.new() |> with_logger(log))
}

fn with_logger(tracer: Tracer, log: Logger) -> Tracer {
  tracer |> tracer.handle(logger.trace_handler(log))
}

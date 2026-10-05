import gloss/logger.{type Logger}
import gloss/tracer.{type Tracer}

pub type AppContext {
  AppContext(tracer: Tracer, log: Logger, nightly_cleanup: Bool)
}

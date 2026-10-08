import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gloss/meta
import gloss/otel
import gloss/tracer

fn recording(sent: Subject(Request(String)), status: Int) {
  fn(req: Request(String)) {
    process.send(sent, req)
    Ok(response.new(status))
  }
}

fn traced(otel: otel.Otel) -> tracer.Tracer {
  tracer.new() |> tracer.handle(otel.handler(otel))
}

pub fn exports_spans_and_logs_on_flush_test() {
  let sent = process.new_subject()
  let assert Ok(otel) =
    otel.config("http://localhost:4318")
    |> otel.service_name("forum")
    |> otel.service_version("1.4.0")
    |> otel.header("Authorization", "Bearer t")
    |> otel.start(recording(sent, 200))

  let t = traced(otel)
  {
    use <- tracer.span(t, "app", "work", fn() { [#("n", meta.Int(1))] })
    Nil
  }
  otel.logger(otel).info("hello", [])
  // Nothing goes until the batch fills or the interval passes.
  assert process.receive(sent, 50) == Error(Nil)

  assert otel.flush(otel, duration.seconds(1)) == Ok(Nil)
  let assert Ok(first) = process.receive(sent, 0)
  let assert Ok(second) = process.receive(sent, 0)
  assert first.path == "/v1/traces"
  assert request.get_header(first, "authorization") == Ok("Bearer t")
  assert string.contains(first.body, "\"name\":\"work\"")
  assert string.contains(first.body, "\"stringValue\":\"forum\"")
  assert string.contains(first.body, "\"stringValue\":\"1.4.0\"")
  assert second.path == "/v1/logs"
  assert string.contains(second.body, "\"stringValue\":\"hello\"")

  // Flushing with nothing buffered returns at once.
  assert otel.flush(otel, duration.milliseconds(100)) == Ok(Nil)
  otel.stop(otel)
}

pub fn the_interval_sends_a_partial_batch_test() {
  let sent = process.new_subject()
  let assert Ok(otel) =
    otel.config("http://localhost:4318")
    |> otel.interval(duration.milliseconds(20))
    |> otel.start(recording(sent, 200))
  traced(otel)
  |> tracer.point("app", "tick", tracer.Info, fn() { [] })
  let assert Ok(req) = process.receive(sent, 1000)
  assert req.path == "/v1/logs"
  otel.stop(otel)
}

pub fn flush_gives_up_while_the_collector_is_down_test() {
  let sent = process.new_subject()
  let assert Ok(otel) =
    otel.config("http://localhost:4318")
    |> otel.start(recording(sent, 503))
  traced(otel)
  |> tracer.emit(fn() {
    tracer.Point(
      source: "app",
      name: "p",
      at: timestamp.system_time(),
      meta: [],
      level: tracer.Info,
      trace: None,
    )
  })
  assert otel.flush(otel, duration.milliseconds(200)) == Error(Nil)
  otel.stop(otel)
}

pub fn an_invalid_endpoint_fails_to_start_test() {
  let assert Error(otel.InvalidEndpoint("localhost:4318")) =
    otel.config("localhost:4318")
    |> otel.start(fn(_) { Ok(response.new(200)) })
}

pub fn a_named_exporter_drops_events_while_down_test() {
  let name = process.new_name("gloss_otel_test")
  let otel = otel.from_name(name)
  // Not started: the handler must not panic.
  traced(otel) |> tracer.point("app", "p", tracer.Info, fn() { [] })
  assert otel.flush(otel, duration.milliseconds(10)) == Error(Nil)
}

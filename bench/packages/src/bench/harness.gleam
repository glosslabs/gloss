//// A small benchmark harness: warm up, then time five rounds and report
//// the median, as operations per second and time per operation.

import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/string

pub type Result {
  Result(name: String, ops_per_sec: Float, ns_per_op: Float)
}

const rounds = 5

/// Time `n` sequential calls of `f`.
pub fn bench(name: String, n: Int, f: fn() -> a) -> Result {
  measure(name, n, fn() { loop(f, n) })
}

/// Time `per_worker` calls of `f` in each of `workers` processes at once.
pub fn bench_concurrent(
  name: String,
  workers: Int,
  per_worker: Int,
  f: fn() -> a,
) -> Result {
  measure(name, workers * per_worker, fn() { concurrent(f, workers, per_worker) })
}

fn measure(name: String, n: Int, run: fn() -> Nil) -> Result {
  // Warm up: one round, untimed.
  run()
  let times =
    list.repeat(Nil, rounds)
    |> list.map(fn(_) {
      let start = now_ns()
      run()
      now_ns() - start
    })
    |> list.sort(int.compare)
  let assert Ok(median) = list.drop(times, rounds / 2) |> list.first
  let ns_per_op = int.to_float(median) /. int.to_float(n)
  let result =
    Result(name:, ops_per_sec: 1_000_000_000.0 /. ns_per_op, ns_per_op:)
  report(result)
  result
}

pub fn report(result: Result) -> Nil {
  io.println(
    string.pad_end(result.name, 52, " ")
    <> string.pad_start(format(result.ops_per_sec), 14, " ")
    <> " ops/s"
    <> string.pad_start(duration(result.ns_per_op), 12, " "),
  )
}

pub fn section(title: String) -> Nil {
  io.println("")
  io.println("## " <> title)
}

fn format(n: Float) -> String {
  let whole = float.round(n)
  int.to_string(whole)
  |> string.reverse
  |> string.to_graphemes
  |> list.sized_chunk(3)
  |> list.map(string.concat)
  |> string.join(",")
  |> string.reverse
}

fn duration(ns: Float) -> String {
  case ns {
    _ if ns <. 1000.0 -> float.to_string(float.to_precision(ns, 0)) <> " ns"
    _ if ns <. 1_000_000.0 ->
      float.to_string(float.to_precision(ns /. 1000.0, 1)) <> " µs"
    _ -> float.to_string(float.to_precision(ns /. 1_000_000.0, 2)) <> " ms"
  }
}

@external(erlang, "bench@harness_ffi", "now_ns")
fn now_ns() -> Int

@external(erlang, "bench@harness_ffi", "loop")
fn loop(f: fn() -> a, n: Int) -> Nil

@external(erlang, "bench@harness_ffi", "concurrent")
fn concurrent(f: fn() -> a, workers: Int, per_worker: Int) -> Nil

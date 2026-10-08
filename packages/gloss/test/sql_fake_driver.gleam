//// An in-memory `pool.Driver` for the core tests. Every statement, connect
//// and close is reported to a subject so tests can assert on exactly what
//// the core sent.

import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/string
import gloss/sql
import gloss/sql/pool

pub fn driver(log: Subject(String)) -> pool.Driver {
  driver_with(log, pipelines: True)
}

/// A driver that can't pipeline statements, so the pool sends a
/// transaction's BEGIN on its own.
pub fn unpipelined(log: Subject(String)) -> pool.Driver {
  driver_with(log, pipelines: False)
}

fn driver_with(log: Subject(String), pipelines pipelines: Bool) -> pool.Driver {
  pool.Driver(name: "fake", placeholder: fn(_) { "?" }, connect: fn() {
    process.send(log, "connect")
    let run_after = case pipelines {
      // Pipelined statements are logged as one entry: "BEGIN; insert x".
      True ->
        Some(fn(before, text, _args, _timeout) {
          process.send(log, string.join(before, "; ") <> "; " <> text)
          respond(text)
        })
      False -> None
    }
    Ok(pool.Connection(
      run: fn(text, _args, _timeout) {
        process.send(log, text)
        respond(text)
      },
      run_after:,
      script: fn(text, _timeout) {
        process.send(log, text)
        Ok(Nil)
      },
      alive: fn() { True },
      transfer: fn(_) { Nil },
      close: fn() { process.send(log, "close") },
      raw: dynamic.string("fake"),
    ))
  })
}

fn respond(text: String) -> Result(sql.Outcome, sql.Error) {
  case text {
    "select id, name from users" ->
      Ok(sql.Outcome(
        rows: [[sql.Int(1), sql.Text("sam")], [sql.Int(2), sql.Null]],
        affected: 2,
      ))
    "select broken" -> Error(sql.QueryFailed("FAKE", "no such table"))
    "select slow" -> Error(sql.QueryTimeout)
    _ -> Ok(sql.Outcome(rows: [], affected: 1))
  }
}

/// Everything logged so far, oldest first.
pub fn drain(log: Subject(String)) -> List(String) {
  case process.receive(log, 0) {
    Ok(entry) -> [entry, ..drain(log)]
    Error(Nil) -> []
  }
}

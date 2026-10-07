//// An in-memory `sql.Driver` for the core tests. Every statement, connect
//// and close is reported to a subject so tests can assert on exactly what
//// the core sent.

import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gloss/sql

pub fn driver(log: Subject(String)) -> sql.Driver {
  sql.Driver(name: "fake", placeholder: fn(_) { "?" }, connect: fn() {
    process.send(log, "connect")
    Ok(sql.Connection(
      run: fn(text, _args, _timeout) {
        process.send(log, text)
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
      },
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

/// Everything logged so far, oldest first.
pub fn drain(log: Subject(String)) -> List(String) {
  case process.receive(log, 0) {
    Ok(entry) -> [entry, ..drain(log)]
    Error(Nil) -> []
  }
}

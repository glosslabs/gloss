import gleeunit/should
import gloss/internal/logger_file_rotation.{Plan, needed, plan}

pub fn needed_test() {
  needed(size: 0, incoming: 500, max_bytes: 100) |> should.be_false
  needed(size: 90, incoming: 10, max_bytes: 100) |> should.be_false
  needed(size: 91, incoming: 10, max_bytes: 100) |> should.be_true
}

pub fn plan_test() {
  plan("log/app.log", 3)
  |> should.equal(
    Plan(delete: ["log/app.log.3"], rename: [
      #("log/app.log.2", "log/app.log.3"),
      #("log/app.log.1", "log/app.log.2"),
      #("log/app.log", "log/app.log.1"),
    ]),
  )
  plan("a.log", 1)
  |> should.equal(Plan(delete: ["a.log.1"], rename: [#("a.log", "a.log.1")]))
  plan("a.log", 0) |> should.equal(Plan(delete: ["a.log"], rename: []))
}

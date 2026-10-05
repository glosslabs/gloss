import gleam/time/calendar.{Date, October, TimeOfDay}
import gleeunit/should
import gloss/scheduler/cron.{type Time, Time}

fn at(minute: Int, hour: Int, day: Int, month: Int, weekday: Int) -> Time {
  Time(minute:, hour:, day:, month:, weekday:)
}

pub fn every_minute_matches_anything_test() {
  cron.every_minute() |> cron.matches(at(59, 23, 31, 12, 6)) |> should.be_true
}

pub fn builder_restricts_fields_test() {
  let c = cron.every_minute() |> cron.hour(3) |> cron.minute(0)
  c |> cron.matches(at(0, 3, 1, 1, 0)) |> should.be_true
  c |> cron.matches(at(1, 3, 1, 1, 0)) |> should.be_false
  c |> cron.matches(at(0, 4, 1, 1, 0)) |> should.be_false
}

pub fn weekday_seven_is_sunday_test() {
  cron.every_minute()
  |> cron.weekday(7)
  |> cron.matches(at(0, 0, 1, 1, 0))
  |> should.be_true
}

pub fn parse_steps_ranges_and_lists_test() {
  let assert Ok(c) = cron.parse("*/15 3 1,15 * 1-5")
  c |> cron.matches(at(30, 3, 1, 6, 3)) |> should.be_true
  c |> cron.matches(at(20, 3, 1, 6, 3)) |> should.be_false
  c |> cron.matches(at(0, 3, 2, 6, 3)) |> should.be_true
  // Both day fields set: a Wednesday that is not the 1st or 15th still runs.
  c |> cron.matches(at(0, 3, 2, 6, 0)) |> should.be_false
}

pub fn parse_bare_value_with_step_runs_to_max_test() {
  let assert Ok(c) = cron.parse("50/5 * * * *")
  c |> cron.matches(at(55, 0, 1, 1, 0)) |> should.be_true
  c |> cron.matches(at(45, 0, 1, 1, 0)) |> should.be_false
}

pub fn parse_rejects_bad_input_test() {
  cron.parse("* * *") |> should.be_error
  cron.parse("60 * * * *") |> should.be_error
  cron.parse("*/0 * * * *") |> should.be_error
  cron.parse("5-1 * * * *") |> should.be_error
  cron.parse("* * 0 * *") |> should.be_error
  cron.parse("x * * * *") |> should.be_error
}

pub fn day_or_weekday_when_both_restricted_test() {
  let assert Ok(c) = cron.parse("0 0 15 * 1")
  // The 15th, not a Monday.
  c |> cron.matches(at(0, 0, 15, 6, 4)) |> should.be_true
  // A Monday, not the 15th.
  c |> cron.matches(at(0, 0, 3, 6, 1)) |> should.be_true
  c |> cron.matches(at(0, 0, 3, 6, 2)) |> should.be_false
}

pub fn time_from_calendar_test() {
  // 2026-10-06 is a Tuesday.
  cron.time_from_calendar(Date(2026, October, 6), TimeOfDay(14, 5, 59, 0))
  |> should.equal(Time(minute: 5, hour: 14, day: 6, month: 10, weekday: 2))
}

import gleam/option.{None, Some}
import gleam/order.{Lt}
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import gloss/scheduler/cron
import gloss/scheduler/schedule
import support.{utc, utc_s}

fn daily_at(hour: Int, minute: Int) -> cron.Cron {
  cron.every_minute() |> cron.hour(hour) |> cron.minute(minute)
}

const started_year = 2026

fn started() {
  utc(started_year, 10, 6, 12, 0)
}

pub fn cron_daily_before_and_after_the_time_test() {
  let s = schedule.cron(daily_at(3, 0))
  schedule.next_run(s, after: utc(2026, 10, 6, 2, 59), started: started())
  |> should.equal(Some(utc(2026, 10, 6, 3, 0)))
  // Strictly after: the matching minute itself moves to the next day.
  schedule.next_run(s, after: utc(2026, 10, 6, 3, 0), started: started())
  |> should.equal(Some(utc(2026, 10, 7, 3, 0)))
}

pub fn cron_ignores_seconds_test() {
  let s = schedule.cron(daily_at(3, 0))
  schedule.next_run(s, after: utc_s(2026, 10, 6, 2, 59, 30), started: started())
  |> should.equal(Some(utc(2026, 10, 6, 3, 0)))
  schedule.next_run(s, after: utc_s(2026, 10, 6, 3, 0, 30), started: started())
  |> should.equal(Some(utc(2026, 10, 7, 3, 0)))
}

pub fn cron_every_fifteen_minutes_test() {
  let assert Ok(c) = cron.parse("*/15 * * * *")
  schedule.next_run(
    schedule.cron(c),
    after: utc(2026, 10, 6, 10, 7),
    started: started(),
  )
  |> should.equal(Some(utc(2026, 10, 6, 10, 15)))
}

pub fn cron_weekday_test() {
  let assert Ok(c) = cron.parse("0 9 * * 1")
  // Tuesday the 6th -> Monday the 12th.
  schedule.next_run(
    schedule.cron(c),
    after: utc(2026, 10, 6, 10, 0),
    started: started(),
  )
  |> should.equal(Some(utc(2026, 10, 12, 9, 0)))
}

pub fn cron_in_fixed_offset_zone_test() {
  let zone = schedule.Fixed(duration.minutes(330))
  let s = schedule.cron_in(daily_at(0, 0), zone)
  // Local midnight on the 7th in UTC+05:30 is 18:30 UTC on the 6th.
  schedule.next_run(s, after: utc(2026, 10, 6, 0, 0), started: started())
  |> should.equal(Some(utc(2026, 10, 6, 18, 30)))
}

pub fn cron_jumps_months_test() {
  let assert Ok(c) = cron.parse("0 0 1 12 *")
  schedule.next_run(
    schedule.cron(c),
    after: utc(2026, 10, 6, 0, 0),
    started: started(),
  )
  |> should.equal(Some(utc(2026, 12, 1, 0, 0)))
}

pub fn cron_finds_leap_day_test() {
  let assert Ok(c) = cron.parse("0 12 29 2 *")
  schedule.next_run(
    schedule.cron(c),
    after: utc(2026, 10, 6, 0, 0),
    started: started(),
  )
  |> should.equal(Some(utc(2028, 2, 29, 12, 0)))
}

pub fn cron_unsatisfiable_is_none_test() {
  let assert Ok(c) = cron.parse("0 0 31 2 *")
  schedule.next_run(
    schedule.cron(c),
    after: utc(2026, 10, 6, 0, 0),
    started: started(),
  )
  |> should.equal(None)
}

/// A zone like central Europe: +01:00, moving to +02:00 at 01:00 UTC on
/// 2026-03-29 and back at 01:00 UTC on 2026-10-25.
fn europe() -> schedule.Zone {
  schedule.Custom(fn(at) {
    let summer_from = utc(2026, 3, 29, 1, 0)
    let summer_to = utc(2026, 10, 25, 1, 0)
    case timestamp.compare(at, summer_from), timestamp.compare(at, summer_to) {
      Lt, _ -> duration.hours(1)
      _, Lt -> duration.hours(2)
      _, _ -> duration.hours(1)
    }
  })
}

pub fn cron_skips_minute_removed_by_spring_forward_test() {
  // 02:30 local does not exist on 2026-03-29; the next one is the day after.
  let s = schedule.cron_in(daily_at(2, 30), europe())
  schedule.next_run(s, after: utc(2026, 3, 28, 12, 0), started: started())
  |> should.equal(Some(utc(2026, 3, 30, 0, 30)))
}

pub fn cron_runs_twice_in_minute_repeated_by_fall_back_test() {
  let s = schedule.cron_in(daily_at(2, 30), europe())
  let first =
    schedule.next_run(s, after: utc(2026, 10, 24, 12, 0), started: started())
  first |> should.equal(Some(utc(2026, 10, 25, 0, 30)))
  let assert Some(first) = first
  schedule.next_run(s, after: first, started: started())
  |> should.equal(Some(utc(2026, 10, 25, 1, 30)))
}

pub fn every_is_anchored_to_start_test() {
  let s = schedule.every(duration.seconds(30))
  let st = started()
  schedule.next_run(s, after: st, started: st)
  |> should.equal(Some(timestamp.add(st, duration.seconds(30))))
  schedule.next_run(
    s,
    after: timestamp.add(st, duration.seconds(30)),
    started: st,
  )
  |> should.equal(Some(timestamp.add(st, duration.seconds(60))))
  schedule.next_run(
    s,
    after: timestamp.add(st, duration.seconds(45)),
    started: st,
  )
  |> should.equal(Some(timestamp.add(st, duration.seconds(60))))
  schedule.next_run(
    s,
    after: timestamp.add(st, duration.seconds(-10)),
    started: st,
  )
  |> should.equal(Some(timestamp.add(st, duration.seconds(30))))
}

pub fn every_does_not_burst_after_late_wakeup_test() {
  let s = schedule.every(duration.seconds(30))
  let st = started()
  schedule.next_run(
    s,
    after: timestamp.add(st, duration.seconds(95)),
    started: st,
  )
  |> should.equal(Some(timestamp.add(st, duration.seconds(120))))
}

pub fn every_zero_never_runs_test() {
  schedule.next_run(
    schedule.every(duration.seconds(0)),
    after: started(),
    started: started(),
  )
  |> should.equal(None)
}

pub fn at_test() {
  let when = utc(2026, 10, 6, 13, 0)
  schedule.next_run(schedule.at(when), after: started(), started: started())
  |> should.equal(Some(when))
  schedule.next_run(schedule.at(when), after: when, started: started())
  |> should.equal(None)
}

pub fn after_test() {
  let s = schedule.after(duration.minutes(5))
  let st = started()
  let due = timestamp.add(st, duration.minutes(5))
  schedule.next_run(s, after: st, started: st) |> should.equal(Some(due))
  schedule.next_run(s, after: due, started: st) |> should.equal(None)
}

pub fn offset_at_test() {
  schedule.offset_at(schedule.Utc, at: started())
  |> should.equal(duration.seconds(0))
  schedule.offset_at(schedule.Fixed(duration.hours(-5)), at: started())
  |> should.equal(duration.hours(-5))
  schedule.offset_at(europe(), at: utc(2026, 7, 1, 0, 0))
  |> should.equal(duration.hours(2))
  // Local depends on the machine's zone; only check it is a whole number of
  // minutes within a day.
  let #(secs, nanos) =
    duration.to_seconds_and_nanoseconds(schedule.offset_at(
      schedule.Local,
      at: started(),
    ))
  nanos |> should.equal(0)
  { secs % 60 == 0 && secs > -86_400 && secs < 86_400 } |> should.be_true
}

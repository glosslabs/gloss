//// When a task runs: on a cron schedule in a time zone, at a fixed interval,
//// once at an instant, or once after a delay.
////
//// ```gleam
//// schedule.cron(cron.every_minute() |> cron.hour(3) |> cron.minute(0))  // 03:00 UTC daily
//// schedule.cron_in(cron.every_minute() |> cron.minute(0), schedule.Local)
//// schedule.every(duration.seconds(30))
//// schedule.after(duration.minutes(5))
//// ```
////
//// Nothing here waits or runs anything; `next_run` only computes instants.
//// Runs missed while the application was down are not caught up.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/order.{Gt, Lt}
import gleam/time/calendar.{TimeOfDay}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import gloss/scheduler/cron.{type Cron}

/// The time zone a cron schedule is evaluated in.
///
/// With `Local` and `Custom` the offset can change over the year. Minutes a
/// spring-forward transition removes do not exist, so a schedule set in them
/// does not run that day; minutes a fall-back transition repeats exist
/// twice, so a schedule set in them runs twice. `Utc` and `Fixed` have no
/// transitions.
pub type Zone {
  Utc
  /// The machine's zone as configured in the operating system.
  Local
  /// A constant offset from UTC, e.g. `Fixed(duration.hours(-5))`.
  Fixed(offset: Duration)
  /// Any rule for the offset at an instant, e.g. a named IANA zone resolved
  /// by a time zone package.
  Custom(offset_at: fn(Timestamp) -> Duration)
}

pub type Schedule {
  /// Whenever the cron expression matches, to the minute, in `zone`.
  Cron(cron: Cron, zone: Zone)
  /// Every `interval` from when the scheduler started. A late wakeup fires
  /// once, then falls back into step; it does not burst to catch up.
  Every(interval: Duration)
  /// Once, at `when`. If `when` has already passed when the scheduler
  /// starts, it runs once straight away.
  At(when: Timestamp)
  /// Once, `delay` after the scheduler started.
  After(delay: Duration)
}

/// A cron schedule in UTC.
pub fn cron(cron: Cron) -> Schedule {
  Cron(cron:, zone: Utc)
}

/// A cron schedule in the given zone.
pub fn cron_in(cron: Cron, zone: Zone) -> Schedule {
  Cron(cron:, zone:)
}

pub fn every(interval: Duration) -> Schedule {
  Every(interval:)
}

pub fn at(when: Timestamp) -> Schedule {
  At(when:)
}

pub fn after(delay: Duration) -> Schedule {
  After(delay:)
}

/// The zone's offset from UTC at an instant.
pub fn offset_at(zone: Zone, at at: Timestamp) -> Duration {
  case zone {
    Utc -> calendar.utc_offset
    Local -> {
      let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(at)
      duration.seconds(local_offset_seconds(seconds))
    }
    Fixed(offset) -> offset
    Custom(offset_at) -> offset_at(at)
  }
}

/// How far ahead `next_run` searches for a cron match before giving up.
const search_limit_days = 1830

/// The first instant strictly after `after` at which the schedule fires, or
/// `None` when it never fires again. `started` is when the scheduler
/// started; `Every` and `After` are anchored to it.
///
/// A cron schedule that cannot match in the next five years (such as
/// `0 0 31 2 *`) gives `None`.
pub fn next_run(
  schedule: Schedule,
  after after: Timestamp,
  started started: Timestamp,
) -> Option(Timestamp) {
  case schedule {
    Every(interval) -> next_every(interval, after, started)
    After(delay) -> once(timestamp.add(started, delay), after)
    At(when) -> once(when, after)
    Cron(cron, zone) -> next_cron(cron, zone, after)
  }
}

fn once(when: Timestamp, after: Timestamp) -> Option(Timestamp) {
  case timestamp.compare(when, after) {
    Gt -> Some(when)
    _ -> None
  }
}

fn next_every(
  interval: Duration,
  after: Timestamp,
  started: Timestamp,
) -> Option(Timestamp) {
  let step = nanoseconds(interval)
  case step > 0 {
    False -> None
    True ->
      case timestamp.compare(after, started) {
        Lt -> Some(timestamp.add(started, interval))
        _ -> {
          let elapsed = nanoseconds(timestamp.difference(started, after))
          let k = elapsed / step + 1
          Some(timestamp.add(started, duration.nanoseconds(k * step)))
        }
      }
  }
}

fn next_cron(cron: Cron, zone: Zone, after: Timestamp) -> Option(Timestamp) {
  let limit = timestamp.add(after, duration.hours(24 * search_limit_days))
  let first = timestamp.add(truncate_to_minute(after), duration.minutes(1))
  search(cron, zone, first, limit)
}

// Walk candidate minutes forward. A mismatch on the date jumps to the next
// local midnight, on the hour to the next local hour, on the minute to the
// next minute, so even a yearly schedule is found in a few thousand steps.
fn search(
  cron: Cron,
  zone: Zone,
  candidate: Timestamp,
  limit: Timestamp,
) -> Option(Timestamp) {
  case timestamp.compare(candidate, limit) {
    Gt -> None
    _ -> {
      let offset = offset_at(zone, candidate)
      let #(date, tod) = timestamp.to_calendar(candidate, offset)
      let time = cron.time_from_calendar(date, tod)
      let next_minute = timestamp.add(candidate, duration.minutes(1))
      case
        cron.matches_date(cron, at: time),
        cron.matches_hour(cron, at: time),
        cron.matches_minute(cron, at: time)
      {
        True, True, True -> Some(candidate)
        False, _, _ -> {
          let midnight =
            timestamp.from_calendar(date, TimeOfDay(0, 0, 0, 0), offset)
          let jump = timestamp.add(midnight, duration.hours(24))
          search(cron, zone, latest(jump, next_minute), limit)
        }
        True, False, _ -> {
          let top =
            timestamp.from_calendar(date, TimeOfDay(tod.hours, 0, 0, 0), offset)
          let jump = timestamp.add(top, duration.hours(1))
          search(cron, zone, latest(jump, next_minute), limit)
        }
        True, True, False -> search(cron, zone, next_minute, limit)
      }
    }
  }
}

fn latest(a: Timestamp, b: Timestamp) -> Timestamp {
  case timestamp.compare(a, b) {
    Lt -> b
    _ -> a
  }
}

fn truncate_to_minute(t: Timestamp) -> Timestamp {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(t)
  let rem = case int.modulo(seconds, 60) {
    Ok(rem) -> rem
    Error(Nil) -> 0
  }
  timestamp.from_unix_seconds(seconds - rem)
}

fn nanoseconds(d: Duration) -> Int {
  let #(seconds, nanos) = duration.to_seconds_and_nanoseconds(d)
  seconds * 1_000_000_000 + nanos
}

@external(erlang, "gloss@scheduler@schedule_ffi", "local_offset_seconds")
fn local_offset_seconds(unix_seconds: Int) -> Int

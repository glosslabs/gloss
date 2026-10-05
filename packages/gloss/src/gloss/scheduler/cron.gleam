//// Cron schedules, built in code or parsed from five-field expressions
//// (minute, hour, day of month, month, weekday).
////
//// Build one by starting from `every_minute` and restricting fields:
////
//// ```gleam
//// cron.every_minute() |> cron.hour(3) |> cron.minute(0)   // 03:00 daily
//// cron.every_minute() |> cron.minute(0) |> cron.weekdays([1, 5])
//// ```
////
//// `parse` supports `*`, values, lists (`1,15`), ranges (`1-5`) and steps
//// (`*/10`). Weekday is 0-7 with both 0 and 7 meaning Sunday.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date, type TimeOfDay}

pub opaque type Cron {
  Cron(minute: Field, hour: Field, day: Field, month: Field, weekday: Field)
}

/// A field is either unrestricted (`*`) or a set of allowed values.
type Field {
  Any
  Only(List(Int))
}

/// A point in time, resolved to the minute. `weekday` is 0-6, Sunday is 0.
pub type Time {
  Time(minute: Int, hour: Int, day: Int, month: Int, weekday: Int)
}

/// The `Time` of a calendar date and time of day (seconds are dropped).
pub fn time_from_calendar(date: Date, time: TimeOfDay) -> Time {
  let weekday = case calendar.day_of_week(date) {
    calendar.Sunday -> 0
    calendar.Monday -> 1
    calendar.Tuesday -> 2
    calendar.Wednesday -> 3
    calendar.Thursday -> 4
    calendar.Friday -> 5
    calendar.Saturday -> 6
  }
  Time(
    minute: time.minutes,
    hour: time.hours,
    day: date.day,
    month: calendar.month_to_int(date.month),
    weekday:,
  )
}

/// The schedule that matches every minute, `* * * * *`. Restrict it with the
/// functions below.
pub fn every_minute() -> Cron {
  Cron(minute: Any, hour: Any, day: Any, month: Any, weekday: Any)
}

/// Run only at this minute of the hour (0-59).
pub fn minute(cron: Cron, minute: Int) -> Cron {
  minutes(cron, [minute])
}

/// Run only at these minutes of the hour (0-59).
pub fn minutes(cron: Cron, minutes: List(Int)) -> Cron {
  Cron(..cron, minute: Only(minutes))
}

/// Run only during this hour (0-23).
pub fn hour(cron: Cron, hour: Int) -> Cron {
  hours(cron, [hour])
}

/// Run only during these hours (0-23).
pub fn hours(cron: Cron, hours: List(Int)) -> Cron {
  Cron(..cron, hour: Only(hours))
}

/// Run only on this day of the month (1-31).
pub fn day(cron: Cron, day: Int) -> Cron {
  days(cron, [day])
}

/// Run only on these days of the month (1-31).
pub fn days(cron: Cron, days: List(Int)) -> Cron {
  Cron(..cron, day: Only(days))
}

/// Run only in this month (1-12).
pub fn month(cron: Cron, month: Int) -> Cron {
  months(cron, [month])
}

/// Run only in these months (1-12).
pub fn months(cron: Cron, months: List(Int)) -> Cron {
  Cron(..cron, month: Only(months))
}

/// Run only on this weekday (0-7, Sunday is 0 or 7).
pub fn weekday(cron: Cron, weekday: Int) -> Cron {
  weekdays(cron, [weekday])
}

/// Run only on these weekdays (0-7, Sunday is 0 or 7). As in cron, when both
/// a day of the month and a weekday are set, either one matching is enough.
pub fn weekdays(cron: Cron, weekdays: List(Int)) -> Cron {
  Cron(..cron, weekday: fold_sunday(Only(weekdays)))
}

pub fn parse(expression: String) -> Result(Cron, String) {
  case
    string.split(string.trim(expression), " ") |> list.filter(fn(s) { s != "" })
  {
    [mi, h, d, mo, w] -> {
      use minute <- result.try(field(mi, 0, 59))
      use hour <- result.try(field(h, 0, 23))
      use day <- result.try(field(d, 1, 31))
      use month <- result.try(field(mo, 1, 12))
      use weekday <- result.try(field(w, 0, 7))
      Ok(Cron(minute:, hour:, day:, month:, weekday: fold_sunday(weekday)))
    }
    parts ->
      Error("expected 5 fields, got " <> int.to_string(list.length(parts)))
  }
}

pub fn matches(cron: Cron, at time: Time) -> Bool {
  matches_date(cron, at: time)
  && matches_hour(cron, at: time)
  && matches_minute(cron, at: time)
}

/// Whether the month, day of month and weekday fields match.
pub fn matches_date(cron: Cron, at time: Time) -> Bool {
  let day_matches = case cron.day, cron.weekday {
    // Vixie cron: when both day fields are restricted, either may match.
    Only(_), Only(_) ->
      allows(cron.day, time.day) || allows(cron.weekday, time.weekday)
    _, _ -> allows(cron.day, time.day) && allows(cron.weekday, time.weekday)
  }
  allows(cron.month, time.month) && day_matches
}

/// Whether the hour field matches.
pub fn matches_hour(cron: Cron, at time: Time) -> Bool {
  allows(cron.hour, time.hour)
}

/// Whether the minute field matches.
pub fn matches_minute(cron: Cron, at time: Time) -> Bool {
  allows(cron.minute, time.minute)
}

fn allows(field: Field, value: Int) -> Bool {
  case field {
    Any -> True
    Only(values) -> list.contains(values, value)
  }
}

fn fold_sunday(field: Field) -> Field {
  case field {
    Any -> Any
    Only(values) ->
      Only(
        list.map(values, fn(v) {
          case v {
            7 -> 0
            _ -> v
          }
        }),
      )
  }
}

fn field(text: String, min: Int, max: Int) -> Result(Field, String) {
  case text {
    "*" -> Ok(Any)
    _ -> {
      string.split(text, ",")
      |> list.try_map(fn(part) { element(part, min, max) })
      |> result.map(fn(groups) { Only(list.flatten(groups)) })
    }
  }
}

fn element(text: String, min: Int, max: Int) -> Result(List(Int), String) {
  let #(range, step) = case string.split(text, "/") {
    [r, s] -> #(r, int.parse(s) |> result.replace_error(bad(text)))
    _ -> #(text, Ok(1))
  }
  use step <- result.try(step)
  use #(lo, hi) <- result.try(case range {
    "*" -> Ok(#(min, max))
    _ ->
      case string.split(range, "-") {
        [a, b] -> {
          use lo <- result.try(bounded(a, min, max, text))
          use hi <- result.try(bounded(b, min, max, text))
          Ok(#(lo, hi))
        }
        [a] -> {
          use lo <- result.try(bounded(a, min, max, text))
          // A bare value with a step runs from that value to the max.
          case step {
            1 -> Ok(#(lo, lo))
            _ -> Ok(#(lo, max))
          }
        }
        _ -> Error(bad(text))
      }
  })
  case step < 1 || lo > hi {
    True -> Error(bad(text))
    False -> Ok(list.filter(ints(lo, hi), fn(v) { { v - lo } % step == 0 }))
  }
}

fn bounded(
  text: String,
  min: Int,
  max: Int,
  whole: String,
) -> Result(Int, String) {
  case int.parse(text) {
    Ok(v) if v >= min && v <= max -> Ok(v)
    _ -> Error(bad(whole))
  }
}

fn bad(text: String) -> String {
  "invalid field \"" <> text <> "\""
}

fn ints(lo: Int, hi: Int) -> List(Int) {
  case lo > hi {
    True -> []
    False -> [lo, ..ints(lo + 1, hi)]
  }
}

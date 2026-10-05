import gleam/erlang/process.{type Subject}
import gleam/time/calendar.{Date, TimeOfDay}
import gleam/time/timestamp.{type Timestamp}

/// A UTC timestamp from civil fields.
pub fn utc(y: Int, mo: Int, d: Int, h: Int, mi: Int) -> Timestamp {
  utc_s(y, mo, d, h, mi, 0)
}

pub fn utc_s(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int) -> Timestamp {
  let assert Ok(month) = calendar.month_from_int(mo)
  timestamp.from_calendar(
    Date(y, month, d),
    TimeOfDay(h, mi, s, 0),
    calendar.utc_offset,
  )
}

/// Everything currently queued on a subject, in order, without waiting.
pub fn drain(subject: Subject(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(x) -> [x, ..drain(subject)]
    Error(Nil) -> []
  }
}

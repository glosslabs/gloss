//// The current time, as a value code is given rather than reads itself.
////
//// Code that stamps records or checks expiry takes a `Clock` in its
//// builder, so a test can hand it one that stands still or moves only when
//// told (see `gloss/testing/clock` in gloss_test):
////
//// ```gleam
//// pub fn new(threads: ThreadStore, clock: Clock) -> Forum {
////   Forum(threads:, clock:)
//// }
////
//// let at = clock.now(forum.clock)
//// ```

import gleam/time/timestamp.{type Timestamp}

pub opaque type Clock {
  Clock(now: fn() -> Timestamp)
}

/// The system's wall clock.
pub fn system() -> Clock {
  Clock(now: timestamp.system_time)
}

/// A clock that always reads `at`.
pub fn fixed(at: Timestamp) -> Clock {
  Clock(now: fn() { at })
}

/// A clock that reads the time from `now`.
pub fn new(now: fn() -> Timestamp) -> Clock {
  Clock(now:)
}

pub fn now(clock: Clock) -> Timestamp {
  clock.now()
}

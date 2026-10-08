import { Ok, Error } from "../gleam.mjs";
import { unix_epoch } from "../../gleam_time/gleam/time/timestamp.mjs";

// gleam_time keeps its Timestamp class private; its epoch is an instance.
const Timestamp = unix_epoch.constructor;
import { Date, TimeOfDay } from "../../gleam_time/gleam/time/calendar.mjs";

// Rows are arrays, which is how Gleam represents tuples here, so
// `decode.field(N, ..)` reaches any column.
export function row(cells) {
  return cells.toArray();
}

export function coerce(value) {
  return value;
}

export function timestamp(value) {
  return value instanceof Timestamp ? new Ok(value) : new Error(undefined);
}

export function date(value) {
  return value instanceof Date ? new Ok(value) : new Error(undefined);
}

export function time_of_day(value) {
  return value instanceof TimeOfDay ? new Ok(value) : new Error(undefined);
}

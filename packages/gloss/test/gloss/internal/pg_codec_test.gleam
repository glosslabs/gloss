import gleam/option.{None, Some}
import gleam/time/calendar
import gleam/time/timestamp
import gloss/database/sql
import gloss/internal/pg_codec as codec

fn decode(oid: Int, text: String) -> sql.Value {
  codec.decode(oid, <<text:utf8>>)
}

pub fn decodes_scalars_test() {
  assert decode(16, "t") == sql.Bool(True)
  assert decode(20, "-9000000000") == sql.Int(-9_000_000_000)
  assert decode(701, "1.5") == sql.Float(1.5)
  assert decode(701, "3") == sql.Float(3.0)
  assert decode(701, "1e+20") == sql.Float(1.0e20)
  assert decode(701, "NaN") == sql.Text("NaN")
  assert decode(17, "\\x00ff") == sql.Bytes(<<0, 255>>)
  assert decode(2950, "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
    == sql.Text("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
}

pub fn decodes_dates_and_times_test() {
  assert decode(1082, "2024-02-29")
    == sql.Date(calendar.Date(2024, calendar.February, 29))
  assert decode(1082, "infinity") == sql.Text("infinity")
  assert decode(1083, "03:04:05.25")
    == sql.Time(calendar.TimeOfDay(3, 4, 5, 250_000_000))
  assert decode(1184, "2024-01-02 03:04:05.5+00")
    == sql.Timestamp(timestamp.from_unix_seconds_and_nanoseconds(
      1_704_164_645,
      500_000_000,
    ))
  assert decode(1184, "2024-01-02 08:34:05+05:30")
    == sql.Timestamp(timestamp.from_unix_seconds(1_704_164_645))
  assert decode(1114, "2024-01-02 03:04:05")
    == sql.Timestamp(timestamp.from_unix_seconds(1_704_164_645))
}

pub fn decodes_arrays_test() {
  assert decode(1007, "{1,2,NULL}")
    == sql.Array([sql.Int(1), sql.Int(2), sql.Null])
  assert decode(1009, "{a,\"b c\",\"d\\\"e\",\"NULL\"}")
    == sql.Array([
      sql.Text("a"),
      sql.Text("b c"),
      sql.Text("d\"e"),
      sql.Text("NULL"),
    ])
  assert decode(1007, "{{1,2},{3,4}}")
    == sql.Array([
      sql.Array([sql.Int(1), sql.Int(2)]),
      sql.Array([sql.Int(3), sql.Int(4)]),
    ])
  assert decode(1007, "[0:1]={5,6}") == sql.Array([sql.Int(5), sql.Int(6)])
  assert decode(1007, "{}") == sql.Array([])
}

pub fn encodes_arguments_test() {
  assert codec.encode(sql.Null) == None
  assert codec.encode(sql.Bool(False)) == Some(#(0, <<"f":utf8>>))
  assert codec.encode(sql.Bytes(<<1>>)) == Some(#(1, <<1>>))
  assert codec.encode(sql.Date(calendar.Date(812, calendar.March, 4)))
    == Some(#(0, <<"0812-03-04":utf8>>))
  assert codec.encode(sql.Time(calendar.TimeOfDay(1, 2, 3, 4000)))
    == Some(#(0, <<"01:02:03.000004":utf8>>))
  assert codec.encode(sql.Timestamp(timestamp.from_unix_seconds(0)))
    == Some(#(0, <<"1970-01-01T00:00:00Z":utf8>>))
  assert codec.encode(
      sql.Array([sql.Text("a\"b"), sql.Null, sql.Array([sql.Int(1)])]),
    )
    == Some(#(0, <<"{\"a\\\"b\",NULL,{\"1\"}}":utf8>>))
}

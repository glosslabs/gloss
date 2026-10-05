import gleeunit/should
import gloss/meta

pub fn to_string_test() {
  meta.to_string(meta.String("x")) |> should.equal("x")
  meta.to_string(meta.Int(3)) |> should.equal("3")
  meta.to_string(meta.Float(1.5)) |> should.equal("1.5")
  meta.to_string(meta.Bool(True)) |> should.equal("true")
  meta.to_string(meta.Bool(False)) |> should.equal("false")
}

pub fn format_empty_test() {
  meta.format([]) |> should.equal("")
}

pub fn format_mixed_test() {
  meta.format([
    #("transfer", meta.String("t-17")),
    #("count", meta.Int(3)),
    #("ratio", meta.Float(0.5)),
    #("ok", meta.Bool(True)),
  ])
  |> should.equal("transfer=\"t-17\" count=3 ratio=0.5 ok=true")
}

pub fn format_quotes_and_escapes_test() {
  meta.format([#("k", meta.String("a \"b\" \\ c\nd"))])
  |> should.equal("k=\"a \\\"b\\\" \\\\ c\\nd\"")
}

pub fn get_test() {
  let m = [#("a", meta.Int(1)), #("a", meta.Int(2)), #("b", meta.Bool(False))]
  meta.get(m, "a") |> should.equal(Ok(meta.Int(1)))
  meta.get(m, "b") |> should.equal(Ok(meta.Bool(False)))
  meta.get(m, "zzz") |> should.equal(Error(Nil))
}

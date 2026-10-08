import gleam/bit_array
import gleam/bytes_tree
import gleam/int
import gloss/redis/internal/resp.{
  Array, Bulk, Failure, Incomplete, Integer, Malformed, Null, Simple,
}

pub fn encodes_commands_as_bulk_arrays_test() {
  assert resp.encode([<<"SET">>, <<"k">>, <<"héllo">>])
    |> bytes_tree.to_bit_array
    == <<"*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$6\r\nhéllo\r\n":utf8>>
  assert resp.encode([<<"PING">>]) |> bytes_tree.to_bit_array
    == <<"*1\r\n$4\r\nPING\r\n">>
}

pub fn parses_each_reply_type_test() {
  assert resp.parse(<<"+OK\r\n">>) == Ok(#(Simple("OK"), <<>>))
  assert resp.parse(<<"-WRONGTYPE bad\r\n">>)
    == Ok(#(Failure("WRONGTYPE bad"), <<>>))
  assert resp.parse(<<":-42\r\n">>) == Ok(#(Integer(-42), <<>>))
  assert resp.parse(<<"$5\r\nhello\r\n">>) == Ok(#(Bulk(<<"hello">>), <<>>))
  assert resp.parse(<<"$0\r\n\r\n">>) == Ok(#(Bulk(<<>>), <<>>))
  assert resp.parse(<<"$-1\r\n">>) == Ok(#(Null, <<>>))
  assert resp.parse(<<"*-1\r\n">>) == Ok(#(Null, <<>>))
  assert resp.parse(<<"*0\r\n">>) == Ok(#(Array([]), <<>>))
}

pub fn bulk_strings_may_hold_crlf_and_binary_test() {
  assert resp.parse(<<"$4\r\na\r\nb\r\n">>) == Ok(#(Bulk(<<"a\r\nb">>), <<>>))
  assert resp.parse(<<"$2\r\n", 0, 255, "\r\n">>)
    == Ok(#(Bulk(<<0, 255>>), <<>>))
}

pub fn parses_nested_arrays_and_leaves_the_rest_test() {
  let data = <<"*2\r\n*2\r\n:1\r\n$-1\r\n+x\r\n:7\r\n">>
  assert resp.parse(data)
    == Ok(#(Array([Array([Integer(1), Null]), Simple("x")]), <<":7\r\n">>))
}

pub fn every_split_point_is_incomplete_test() {
  let whole = <<"*3\r\n$3\r\nfoo\r\n:12\r\n*1\r\n$-1\r\n">>
  let size = bit_array.byte_size(whole)
  int.range(from: 0, to: size, with: Nil, run: fn(_, n) {
    let assert Ok(prefix) = bit_array.slice(whole, 0, n)
    assert resp.parse(prefix) == Error(Incomplete)
  })
  assert resp.parse(whole)
    == Ok(#(Array([Bulk(<<"foo">>), Integer(12), Array([Null])]), <<>>))
}

pub fn parse_all_keeps_a_partial_reply_test() {
  assert resp.parse_all(<<"+OK\r\n:1\r\n$5\r\nhel">>)
    == Ok(#([Simple("OK"), Integer(1)], <<"$5\r\nhel">>))
  assert resp.parse_all(<<>>) == Ok(#([], <<>>))
}

pub fn malformed_replies_are_errors_test() {
  let assert Error(Malformed(_)) = resp.parse(<<"?x\r\n">>)
  let assert Error(Malformed(_)) = resp.parse(<<":abc\r\n">>)
  let assert Error(Malformed(_)) = resp.parse(<<"$2\r\nabcd\r\n">>)
  let assert Error(_) = resp.parse_all(<<"+OK\r\n!\r\n">>)
}

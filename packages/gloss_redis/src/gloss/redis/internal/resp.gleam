//// RESP2: encoding commands and parsing replies.
////
//// <https://redis.io/docs/latest/develop/reference/protocol-spec/>

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/int
import gleam/list

/// A reply as it arrived.
pub type Value {
  Simple(String)
  Failure(String)
  Integer(Int)
  Bulk(BitArray)
  Array(List(Value))
  /// A null bulk string or null array.
  Null
}

pub type ParseError {
  /// More bytes are needed.
  Incomplete
  Malformed(String)
}

/// A command as an array of bulk strings.
pub fn encode(arguments: List(BitArray)) -> BytesTree {
  let header = "*" <> int.to_string(list.length(arguments)) <> "\r\n"
  list.fold(arguments, bytes_tree.from_string(header), fn(tree, argument) {
    tree
    |> bytes_tree.append_string(
      "$" <> int.to_string(bit_array.byte_size(argument)) <> "\r\n",
    )
    |> bytes_tree.append(argument)
    |> bytes_tree.append_string("\r\n")
  })
}

/// One reply from the front of `data`, and the bytes after it.
pub fn parse(data: BitArray) -> Result(#(Value, BitArray), ParseError) {
  case data {
    <<"+":utf8, rest:bits>> -> {
      use #(line, rest) <- try_line(rest)
      Ok(#(Simple(text(line)), rest))
    }
    <<"-":utf8, rest:bits>> -> {
      use #(line, rest) <- try_line(rest)
      Ok(#(Failure(text(line)), rest))
    }
    <<":":utf8, rest:bits>> -> {
      use #(line, rest) <- try_line(rest)
      use n <- try_int(line)
      Ok(#(Integer(n), rest))
    }
    <<"$":utf8, rest:bits>> -> {
      use #(line, rest) <- try_line(rest)
      use size <- try_int(line)
      bulk(rest, size)
    }
    <<"*":utf8, rest:bits>> -> {
      use #(line, rest) <- try_line(rest)
      use count <- try_int(line)
      case count {
        -1 -> Ok(#(Null, rest))
        _ if count < 0 ->
          Error(Malformed("array length " <> int.to_string(count)))
        _ -> elements(rest, count, [])
      }
    }
    <<>> -> Error(Incomplete)
    _ -> Error(Malformed("unknown reply type"))
  }
}

fn bulk(data: BitArray, size: Int) -> Result(#(Value, BitArray), ParseError) {
  case size {
    -1 -> Ok(#(Null, data))
    _ if size < 0 -> Error(Malformed("bulk length " <> int.to_string(size)))
    _ ->
      case data {
        <<body:bytes-size(size), "\r\n":utf8, rest:bits>> ->
          Ok(#(Bulk(body), rest))
        _ ->
          case bit_array.byte_size(data) >= size + 2 {
            True -> Error(Malformed("bulk string not terminated"))
            False -> Error(Incomplete)
          }
      }
  }
}

/// As many whole replies as `data` holds, and the bytes left over.
pub fn parse_all(data: BitArray) -> Result(#(List(Value), BitArray), String) {
  parse_all_loop(data, [])
}

fn parse_all_loop(
  data: BitArray,
  acc: List(Value),
) -> Result(#(List(Value), BitArray), String) {
  case parse(data) {
    Ok(#(value, rest)) -> parse_all_loop(rest, [value, ..acc])
    Error(Incomplete) -> Ok(#(list.reverse(acc), data))
    Error(Malformed(reason)) -> Error(reason)
  }
}

fn elements(
  data: BitArray,
  remaining: Int,
  acc: List(Value),
) -> Result(#(Value, BitArray), ParseError) {
  case remaining {
    0 -> Ok(#(Array(list.reverse(acc)), data))
    _ ->
      case parse(data) {
        Ok(#(value, rest)) -> elements(rest, remaining - 1, [value, ..acc])
        Error(error) -> Error(error)
      }
  }
}

fn try_line(
  data: BitArray,
  next: fn(#(BitArray, BitArray)) -> Result(a, ParseError),
) -> Result(a, ParseError) {
  case split_line(data, 0) {
    Ok(split) -> next(split)
    Error(error) -> Error(error)
  }
}

/// The bytes before the first CRLF, and those after it.
fn split_line(
  data: BitArray,
  at: Int,
) -> Result(#(BitArray, BitArray), ParseError) {
  case data {
    <<line:bytes-size(at), "\r\n":utf8, rest:bits>> -> Ok(#(line, rest))
    <<_:bytes-size(at), _, _:bits>> -> split_line(data, at + 1)
    _ -> Error(Incomplete)
  }
}

fn try_int(
  line: BitArray,
  next: fn(Int) -> Result(a, ParseError),
) -> Result(a, ParseError) {
  case int.parse(text(line)) {
    Ok(n) -> next(n)
    Error(Nil) -> Error(Malformed("bad integer " <> text(line)))
  }
}

fn text(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(s) -> s
    Error(Nil) -> ""
  }
}

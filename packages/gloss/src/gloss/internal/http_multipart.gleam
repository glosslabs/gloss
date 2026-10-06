//// A streaming `multipart/form-data` parser (RFC 7578), with no IO. Feed it
//// the body in pieces of any size; it returns the events those pieces
//// complete.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/uri

pub type Part {
  Part(
    /// The form field's name.
    name: String,
    /// The uploaded file's name, for file fields.
    filename: Option(String),
    /// `text/plain` when the part doesn't say.
    content_type: String,
    /// Every header of the part, with lowercase names.
    headers: List(#(String, String)),
  )
}

pub type Event {
  /// A part begins.
  Start(Part)
  /// Some of the current part's content.
  Data(BitArray)
  /// The current part is complete.
  End
}

pub type ParseError {
  Malformed(reason: String)
  TooManyParts(limit: Int)
}

pub opaque type Parser {
  Parser(delimiter: BitArray, stage: Stage, buffer: BitArray, parts: Int)
}

type Stage {
  /// Before the first delimiter.
  Preamble
  /// Just after a delimiter: `--` ends the body, CRLF starts a part.
  Boundary
  Headers
  Content
  Done
}

/// The most header bytes one part may have.
pub const max_header_bytes = 16_384

pub const max_parts = 1000

/// The `boundary` parameter of a `multipart/form-data` content type.
pub fn boundary(content_type: String) -> Result(String, Nil) {
  case string.split(content_type, ";") {
    [media, ..params] ->
      case string.lowercase(string.trim(media)) {
        "multipart/form-data" ->
          list.find_map(params, fn(param) {
            case string.split_once(string.trim(param), "=") {
              Ok(#(key, value)) ->
                case string.lowercase(string.trim(key)), unquote(value) {
                  "boundary", "" -> Error(Nil)
                  "boundary", value -> Ok(value)
                  _, _ -> Error(Nil)
                }
              Error(Nil) -> Error(Nil)
            }
          })
        _ -> Error(Nil)
      }
    [] -> Error(Nil)
  }
}

pub fn new(boundary: String) -> Parser {
  // A leading CRLF lets the first delimiter match like the rest, whether or
  // not there is a preamble.
  Parser(
    delimiter: <<"\r\n--":utf8, boundary:utf8>>,
    stage: Preamble,
    buffer: <<"\r\n":utf8>>,
    parts: 0,
  )
}

pub fn feed(
  parser: Parser,
  chunk: BitArray,
) -> Result(#(Parser, List(Event)), ParseError) {
  let parser = Parser(..parser, buffer: bit_array.append(parser.buffer, chunk))
  run(parser, [])
}

/// Whether the body ended properly, with the closing delimiter.
pub fn finish(parser: Parser) -> Result(Nil, ParseError) {
  case parser.stage {
    Done -> Ok(Nil)
    _ -> Error(Malformed("the body ended before the closing boundary"))
  }
}

/// Advance as far as the buffer allows. `events` is newest first.
fn run(
  parser: Parser,
  events: List(Event),
) -> Result(#(Parser, List(Event)), ParseError) {
  let stay = Ok(#(parser, list.reverse(events)))
  let delimiter_size = bit_array.byte_size(parser.delimiter)
  case parser.stage {
    Done -> Ok(#(Parser(..parser, buffer: <<>>), list.reverse(events)))

    Preamble ->
      case find(parser.buffer, parser.delimiter) {
        Ok(at) ->
          run(
            Parser(
              ..parser,
              stage: Boundary,
              buffer: drop(parser.buffer, at + delimiter_size),
            ),
            events,
          )
        // Keep only what could be the start of a delimiter.
        Error(Nil) ->
          Ok(#(
            Parser(..parser, buffer: tail(parser.buffer, delimiter_size - 1)),
            list.reverse(events),
          ))
      }

    Boundary ->
      case parser.buffer {
        <<"--":utf8, _:bits>> -> run(Parser(..parser, stage: Done), events)
        <<"\r\n":utf8, rest:bits>> ->
          case parser.parts >= max_parts {
            True -> Error(TooManyParts(max_parts))
            False ->
              run(
                Parser(
                  ..parser,
                  stage: Headers,
                  buffer: rest,
                  parts: parser.parts + 1,
                ),
                events,
              )
          }
        <<_, _, _:bits>> ->
          Error(Malformed("unexpected bytes after a boundary"))
        _ -> stay
      }

    Headers ->
      case find(parser.buffer, <<"\r\n\r\n":utf8>>) {
        Ok(at) -> {
          use part <- result.try(parse_headers(take(parser.buffer, at)))
          run(
            Parser(
              ..parser,
              stage: Content,
              buffer: drop(parser.buffer, at + 4),
            ),
            [Start(part), ..events],
          )
        }
        Error(Nil) ->
          case bit_array.byte_size(parser.buffer) > max_header_bytes {
            True -> Error(Malformed("part headers too large"))
            False -> stay
          }
      }

    Content ->
      case find(parser.buffer, parser.delimiter) {
        Ok(at) -> {
          let events = case at {
            0 -> [End, ..events]
            _ -> [End, Data(take(parser.buffer, at)), ..events]
          }
          run(
            Parser(
              ..parser,
              stage: Boundary,
              buffer: drop(parser.buffer, at + delimiter_size),
            ),
            events,
          )
        }
        Error(Nil) -> {
          // Everything but a tail that could begin a delimiter is content.
          let keep = delimiter_size - 1
          let size = bit_array.byte_size(parser.buffer)
          case size > keep {
            True ->
              Ok(#(
                Parser(..parser, buffer: tail(parser.buffer, keep)),
                list.reverse([Data(take(parser.buffer, size - keep)), ..events]),
              ))
            False -> stay
          }
        }
      }
  }
}

fn parse_headers(block: BitArray) -> Result(Part, ParseError) {
  use text <- result.try(
    bit_array.to_string(block)
    |> result.replace_error(Malformed("part headers are not UTF-8")),
  )
  let headers =
    string.split(text, "\r\n")
    |> list.filter_map(fn(line) {
      case string.split_once(line, ":") {
        Ok(#(name, value)) ->
          Ok(#(string.lowercase(string.trim(name)), string.trim(value)))
        Error(Nil) -> Error(Nil)
      }
    })
  use disposition <- result.try(
    list.key_find(headers, "content-disposition")
    |> result.replace_error(Malformed("a part has no content-disposition")),
  )
  let params = disposition_params(disposition)
  use name <- result.try(
    list.key_find(params, "name")
    |> result.replace_error(Malformed("a part has no name")),
  )
  let filename = case list.key_find(params, "filename*") {
    Ok(extended) -> decode_extended(extended)
    Error(Nil) -> list.key_find(params, "filename")
  }
  Ok(Part(
    name:,
    filename: option.from_result(filename),
    content_type: list.key_find(headers, "content-type")
      |> result.unwrap("text/plain"),
    headers:,
  ))
}

/// `form-data; name="field"; filename="a;b.txt"` to its parameters,
/// respecting quotes.
fn disposition_params(value: String) -> List(#(String, String)) {
  split_unquoted(value, ";")
  |> list.filter_map(fn(param) {
    case string.split_once(string.trim(param), "=") {
      Ok(#(key, value)) ->
        Ok(#(string.lowercase(string.trim(key)), unquote(value)))
      Error(Nil) -> Error(Nil)
    }
  })
}

fn split_unquoted(text: String, separator: String) -> List(String) {
  let #(parts, current, _) =
    string.to_graphemes(text)
    |> list.fold(#([], "", False), fn(state, char) {
      let #(parts, current, quoted) = state
      case char, quoted {
        "\"", _ -> #(parts, current <> char, !quoted)
        c, False if c == separator -> #([current, ..parts], "", False)
        _, _ -> #(parts, current <> char, quoted)
      }
    })
  list.reverse([current, ..parts])
}

fn unquote(value: String) -> String {
  let value = string.trim(value)
  case string.starts_with(value, "\""), string.ends_with(value, "\"") {
    True, True ->
      value
      |> string.drop_start(1)
      |> string.drop_end(1)
      |> string.replace("\\\"", "\"")
      |> string.replace("\\\\", "\\")
    _, _ -> value
  }
}

/// An RFC 8187 value such as `UTF-8''na%C3%AFve.txt`.
fn decode_extended(value: String) -> Result(String, Nil) {
  case string.split(value, "'") {
    [charset, _language, encoded] ->
      case string.lowercase(charset) {
        "utf-8" -> uri.percent_decode(encoded)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn take(bits: BitArray, length: Int) -> BitArray {
  bit_array.slice(bits, 0, length) |> result.unwrap(<<>>)
}

fn drop(bits: BitArray, length: Int) -> BitArray {
  let size = bit_array.byte_size(bits)
  bit_array.slice(bits, length, size - length) |> result.unwrap(<<>>)
}

/// The last `length` bytes, or all of them when there are fewer.
fn tail(bits: BitArray, length: Int) -> BitArray {
  let size = bit_array.byte_size(bits)
  case size > length {
    True -> drop(bits, size - length)
    False -> bits
  }
}

@external(erlang, "gloss@http@server_ffi", "find")
fn find(haystack: BitArray, needle: BitArray) -> Result(Int, Nil)

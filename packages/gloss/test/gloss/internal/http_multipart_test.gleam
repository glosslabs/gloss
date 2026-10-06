import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import gloss/internal/http_multipart.{
  Data, End, Malformed, Part, Start, TooManyParts,
} as multipart

const body =
  "preamble to ignore\r
--XyZ\r
Content-Disposition: form-data; name=\"title\"\r
\r
hello\r
--XyZ\r
Content-Disposition: form-data; name=\"file\"; filename=\"a;b.txt\"\r
Content-Type: text/csv\r
\r
1,2\r
3,4\r
--XyZ--\r
epilogue"

/// Feed `chunks` and collect the events, merging adjacent data so the
/// result doesn't depend on where chunks were split.
fn parse(chunks: List(BitArray)) {
  let #(parser, events) =
    list.fold(chunks, #(multipart.new("XyZ"), []), fn(acc, chunk) {
      let assert Ok(#(parser, events)) = multipart.feed(acc.0, chunk)
      #(parser, list.append(acc.1, events))
    })
  #(multipart.finish(parser), merge(events))
}

fn merge(events: List(multipart.Event)) -> List(multipart.Event) {
  case events {
    [Data(a), Data(b), ..rest] -> merge([Data(bit_array.append(a, b)), ..rest])
    [event, ..rest] -> [event, ..merge(rest)]
    [] -> []
  }
}

fn expected() {
  [
    Start(
      Part(name: "title", filename: None, content_type: "text/plain", headers: [
        #("content-disposition", "form-data; name=\"title\""),
      ]),
    ),
    Data(<<"hello":utf8>>),
    End,
    Start(
      Part(
        name: "file",
        filename: Some("a;b.txt"),
        content_type: "text/csv",
        headers: [
          #(
            "content-disposition",
            "form-data; name=\"file\"; filename=\"a;b.txt\"",
          ),
          #("content-type", "text/csv"),
        ],
      ),
    ),
    Data(<<"1,2\r\n3,4":utf8>>),
    End,
  ]
}

pub fn whole_body_test() {
  parse([bit_array.from_string(body)])
  |> should.equal(#(Ok(Nil), expected()))
}

pub fn one_byte_at_a_time_test() {
  string.to_graphemes(body)
  |> list.map(bit_array.from_string)
  |> parse
  |> should.equal(#(Ok(Nil), expected()))
}

pub fn boundary_test() {
  multipart.boundary("multipart/form-data; boundary=XyZ")
  |> should.equal(Ok("XyZ"))
  multipart.boundary("Multipart/Form-Data; charset=utf-8; boundary=\"a b\"")
  |> should.equal(Ok("a b"))
  multipart.boundary("multipart/mixed; boundary=XyZ")
  |> should.equal(Error(Nil))
  multipart.boundary("multipart/form-data") |> should.equal(Error(Nil))
}

pub fn extended_filename_test() {
  let body =
    "--XyZ\r\nContent-Disposition: form-data; name=\"f\"; filename=\"fallback.txt\"; filename*=UTF-8''na%C3%AFve.txt\r\n\r\nx\r\n--XyZ--\r\n"
  let assert #(Ok(Nil), [Start(Part(filename: Some(name), ..)), ..]) =
    parse([bit_array.from_string(body)])
  name |> should.equal("naïve.txt")
}

pub fn unclosed_body_test() {
  let body = "--XyZ\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx"
  parse([bit_array.from_string(body)]).0
  |> should.equal(
    Error(Malformed("the body ended before the closing boundary")),
  )
}

pub fn malformed_parts_test() {
  let feed = fn(body) {
    multipart.feed(multipart.new("XyZ"), bit_array.from_string(body))
  }
  feed("--XyZ\r\nContent-Type: text/plain\r\n\r\nx")
  |> should.equal(Error(Malformed("a part has no content-disposition")))
  feed("--XyZ\r\n" <> string.repeat("x", 20_000))
  |> should.equal(Error(Malformed("part headers too large")))
  feed("--XyZjunk")
  |> should.equal(Error(Malformed("unexpected bytes after a boundary")))
}

pub fn too_many_parts_test() {
  let part = "--XyZ\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n"
  multipart.feed(
    multipart.new("XyZ"),
    bit_array.from_string(string.repeat(part, 1001) <> "--XyZ--"),
  )
  |> should.equal(Error(TooManyParts(1000)))
}

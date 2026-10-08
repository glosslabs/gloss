//// Just enough XML for S3: elements and their text. The prolog, comments
//// and attributes (S3 only uses `xmlns`) are skipped; entities and CDATA
//// sections are decoded.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Element {
  Element(name: String, children: List(Node))
}

pub type Node {
  Child(Element)
  Text(String)
}

/// The document's root element.
pub fn parse(document: BitArray) -> Result(Element, String) {
  case skip_misc(document) {
    <<"<":utf8, rest:bytes>> -> {
      use #(element, rest) <- result.try(element(rest))
      case skip_misc(rest) {
        <<>> -> Ok(element)
        _ -> Error("content after the root element")
      }
    }
    _ -> Error("no root element")
  }
}

/// The first child element called `name`.
pub fn child(element: Element, name: String) -> Option(Element) {
  list.find_map(element.children, fn(node) {
    case node {
      Child(child) if child.name == name -> Ok(child)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// Every child element called `name`, in order.
pub fn children(element: Element, name: String) -> List(Element) {
  list.filter_map(element.children, fn(node) {
    case node {
      Child(child) if child.name == name -> Ok(child)
      _ -> Error(Nil)
    }
  })
}

/// An element's text, joined.
pub fn text(element: Element) -> String {
  list.map(element.children, fn(node) {
    case node {
      Text(text) -> text
      Child(_) -> ""
    }
  })
  |> string.concat
}

/// The text of the first child called `name`, or `""`.
pub fn child_text(element: Element, name: String) -> String {
  child(element, name) |> option.map(text) |> option.unwrap("")
}

/// Text with `&`, `<`, `>`, `"` and `'` escaped.
pub fn escape(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&apos;")
}

// --- Parsing -------------------------------------------------------------------

/// Whitespace, the XML declaration, processing instructions, comments and
/// a doctype, before or after the root.
fn skip_misc(bytes: BitArray) -> BitArray {
  case bytes {
    <<" ":utf8, rest:bytes>>
    | <<"\n":utf8, rest:bytes>>
    | <<"\r":utf8, rest:bytes>>
    | <<"\t":utf8, rest:bytes>> -> skip_misc(rest)
    <<"<?":utf8, rest:bytes>> -> skip_misc(after(rest, <<"?>":utf8>>))
    <<"<!--":utf8, rest:bytes>> -> skip_misc(after(rest, <<"-->":utf8>>))
    <<"<!":utf8, rest:bytes>> -> skip_misc(after(rest, <<">":utf8>>))
    _ -> bytes
  }
}

/// The bytes after the first `marker`, or nothing.
fn after(bytes: BitArray, marker: BitArray) -> BitArray {
  let size = bit_array.byte_size(marker)
  case bytes {
    <<head:bytes-size(size), rest:bytes>> if head == marker -> rest
    <<_, rest:bytes>> -> after(rest, marker)
    _ -> <<>>
  }
}

/// An element whose `<` has been read.
fn element(bytes: BitArray) -> Result(#(Element, BitArray), String) {
  let #(name, rest) = take_name(bytes, <<>>)
  use name <- result.try(utf8(name))
  case name {
    "" -> Error("an element without a name")
    _ -> {
      let rest = skip_attributes(rest)
      case rest {
        <<"/>":utf8, rest:bytes>> -> Ok(#(Element(name, []), rest))
        <<">":utf8, rest:bytes>> -> {
          use #(children, rest) <- result.try(content(
            rest,
            name,
            [],
            <<>>,
            False,
          ))
          Ok(#(Element(name, children), rest))
        }
        _ -> Error("unterminated tag <" <> name)
      }
    }
  }
}

fn take_name(bytes: BitArray, acc: BitArray) -> #(BitArray, BitArray) {
  case bytes {
    <<c, rest:bytes>>
      if c != 0x20
      && c != 0x0a
      && c != 0x0d
      && c != 0x09
      && c != 0x3e
      && c != 0x2f
      && c != 0x3d
    -> take_name(rest, <<acc:bits, c>>)
    _ -> #(acc, bytes)
  }
}

/// Up to the tag's `>` or `/>`, skipping quoted attribute values.
fn skip_attributes(bytes: BitArray) -> BitArray {
  case bytes {
    <<">":utf8, _:bytes>> | <<"/>":utf8, _:bytes>> -> bytes
    <<"\"":utf8, rest:bytes>> -> skip_attributes(after(rest, <<"\"":utf8>>))
    <<"'":utf8, rest:bytes>> -> skip_attributes(after(rest, <<"'":utf8>>))
    <<_, rest:bytes>> -> skip_attributes(rest)
    _ -> <<>>
  }
}

/// An element's children, up to its closing tag. `text` gathers the
/// current run of character data; `has_child` says whether a child element
/// has been read.
fn content(
  bytes: BitArray,
  name: String,
  acc: List(Node),
  text: BitArray,
  has_child: Bool,
) -> Result(#(List(Node), BitArray), String) {
  case bytes {
    <<"</":utf8, rest:bytes>> -> {
      use acc <- result.try(flush(acc, text, True, has_child))
      let #(closing, rest) = take_name(rest, <<>>)
      case utf8(closing) {
        Ok(closing) if closing == name ->
          case skip_space(rest) {
            <<">":utf8, rest:bytes>> -> Ok(#(list.reverse(acc), rest))
            _ -> Error("unterminated closing tag </" <> name)
          }
        _ -> Error("mismatched closing tag for <" <> name <> ">")
      }
    }
    <<"<!--":utf8, rest:bytes>> ->
      content(after(rest, <<"-->":utf8>>), name, acc, text, has_child)
    <<"<![CDATA[":utf8, rest:bytes>> -> {
      let #(data, rest) = until(rest, <<"]]>":utf8>>, <<>>)
      content(rest, name, acc, <<text:bits, data:bits>>, has_child)
    }
    <<"<?":utf8, rest:bytes>> ->
      content(after(rest, <<"?>":utf8>>), name, acc, text, has_child)
    <<"<":utf8, rest:bytes>> -> {
      use acc <- result.try(flush(acc, text, False, has_child))
      use #(child, rest) <- result.try(element(rest))
      content(rest, name, [Child(child), ..acc], <<>>, True)
    }
    <<"&":utf8, rest:bytes>> -> {
      let #(entity, rest) = until(rest, <<";":utf8>>, <<>>)
      use entity <- result.try(utf8(entity))
      use char <- result.try(entity_text(entity))
      content(rest, name, acc, <<text:bits, char:utf8>>, has_child)
    }
    <<c, rest:bytes>> -> content(rest, name, acc, <<text:bits, c>>, has_child)
    _ -> Error("unterminated element <" <> name <> ">")
  }
}

/// The bytes before the first `marker`, and those after it.
fn until(
  bytes: BitArray,
  marker: BitArray,
  acc: BitArray,
) -> #(BitArray, BitArray) {
  let size = bit_array.byte_size(marker)
  case bytes {
    <<head:bytes-size(size), rest:bytes>> if head == marker -> #(acc, rest)
    <<c, rest:bytes>> -> until(rest, marker, <<acc:bits, c>>)
    _ -> #(acc, <<>>)
  }
}

fn skip_space(bytes: BitArray) -> BitArray {
  case bytes {
    <<" ":utf8, rest:bytes>>
    | <<"\n":utf8, rest:bytes>>
    | <<"\r":utf8, rest:bytes>>
    | <<"\t":utf8, rest:bytes>> -> skip_space(rest)
    _ -> bytes
  }
}

/// Add a run of text to the children. Whitespace-only text is dropped when
/// it sits between elements (`closing` is False before a child element),
/// and kept as the text of an element with no child elements, such as a
/// key made of spaces.
fn flush(
  acc: List(Node),
  text: BitArray,
  closing: Bool,
  has_child: Bool,
) -> Result(List(Node), String) {
  case text, blank(text) {
    <<>>, _ -> Ok(acc)
    _, True if !closing || has_child -> Ok(acc)
    _, _ -> {
      use text <- result.map(utf8(text))
      [Text(text), ..acc]
    }
  }
}

/// Whether bytes are only XML whitespace.
fn blank(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<" ":utf8, rest:bytes>>
    | <<"\n":utf8, rest:bytes>>
    | <<"\r":utf8, rest:bytes>>
    | <<"\t":utf8, rest:bytes>> -> blank(rest)
    _ -> False
  }
}

fn entity_text(entity: String) -> Result(String, String) {
  case entity {
    "amp" -> Ok("&")
    "lt" -> Ok("<")
    "gt" -> Ok(">")
    "quot" -> Ok("\"")
    "apos" -> Ok("'")
    "#x" <> hex | "#X" <> hex -> code_point(int.base_parse(hex, 16), entity)
    "#" <> decimal -> code_point(int.parse(decimal), entity)
    _ -> Error("unknown entity &" <> entity <> ";")
  }
}

fn code_point(n: Result(Int, Nil), entity: String) -> Result(String, String) {
  n
  |> result.try(string.utf_codepoint)
  |> result.map(fn(point) { string.from_utf_codepoints([point]) })
  |> result.replace_error("bad character reference &" <> entity <> ";")
}

fn utf8(bytes: BitArray) -> Result(String, String) {
  bit_array.to_string(bytes) |> result.replace_error("text that isn't UTF-8")
}

/// The element's name with any namespace prefix removed.
pub fn local_name(element: Element) -> String {
  case string.split_once(element.name, ":") {
    Ok(#(_, local)) -> local
    Error(Nil) -> element.name
  }
}

/// `Some(text)` for a child with text, else `None`.
pub fn optional_text(element: Element, name: String) -> Option(String) {
  case child_text(element, name) {
    "" -> None
    text -> Some(text)
  }
}

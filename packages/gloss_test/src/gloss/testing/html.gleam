//// Looking inside HTML in tests, without a full parser: the text a reader
//// would see, and attribute values.
////
//// ```gleam
//// let page = response.text(browser.get(b, "/threads/1"))
//// assert string.contains(html.text(page), "1 reply")
//// let assert [avatar, ..] = html.attribute_values(page, "src")
//// ```

import gleam/list
import gleam/string

/// The text a reader would see: tags, scripts and styles removed, entities
/// decoded and runs of whitespace collapsed to one space.
pub fn text(html: String) -> String {
  html
  |> drop_element("script")
  |> drop_element("style")
  |> strip_tags("")
  |> decode_entities
  |> string.split(" ")
  |> list.flat_map(string.split(_, "\n"))
  |> list.flat_map(string.split(_, "\t"))
  |> list.filter(fn(word) { word != "" })
  |> string.join(" ")
}

/// The value of every `name` attribute, in document order, with entities
/// decoded: `attribute_values(page, "href")`.
pub fn attribute_values(html: String, name: String) -> List(String) {
  let marker = " " <> name <> "=\""
  case string.split(html, marker) {
    [] | [_] -> []
    [_, ..rest] ->
      list.filter_map(rest, fn(after) {
        case string.split_once(after, "\"") {
          Ok(#(value, _)) -> Ok(decode_entities(value))
          Error(Nil) -> Error(Nil)
        }
      })
  }
}

fn drop_element(html: String, tag: String) -> String {
  case string.split_once(html, "<" <> tag) {
    Error(Nil) -> html
    Ok(#(before, after)) ->
      case string.split_once(after, "</" <> tag <> ">") {
        Ok(#(_, rest)) -> before <> " " <> drop_element(rest, tag)
        Error(Nil) -> before
      }
  }
}

fn strip_tags(html: String, acc: String) -> String {
  case string.split_once(html, "<") {
    Error(Nil) -> acc <> html
    Ok(#(text, rest)) ->
      case string.split_once(rest, ">") {
        Ok(#(_, after)) -> strip_tags(after, acc <> text <> " ")
        Error(Nil) -> acc <> text
      }
  }
}

fn decode_entities(text: String) -> String {
  text
  |> string.replace("&lt;", "<")
  |> string.replace("&gt;", ">")
  |> string.replace("&quot;", "\"")
  |> string.replace("&#39;", "'")
  |> string.replace("&#x27;", "'")
  |> string.replace("&nbsp;", " ")
  |> string.replace("&amp;", "&")
}

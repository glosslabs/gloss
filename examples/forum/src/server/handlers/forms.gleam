import gleam/list
import gleam/result
import gloss/http/body.{type Form}

/// A text field's value, or `""` when it wasn't sent.
pub fn value(form: Form, name: String) -> String {
  list.key_find(form.values, name) |> result.unwrap("")
}

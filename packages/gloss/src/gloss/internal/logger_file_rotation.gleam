//// When and how `gloss/logger/file` rotates, with no IO.

import gleam/int
import gleam/list

/// Whether writing `incoming` bytes to a file of `size` bytes should first
/// rotate it. A file is never rotated while empty, so one oversized entry
/// still gets written.
pub fn needed(
  size size: Int,
  incoming incoming: Int,
  max_bytes max_bytes: Int,
) -> Bool {
  size > 0 && size + incoming > max_bytes
}

/// The file operations that rotate `path`, keeping `keep` old files named
/// `path.1` (newest) to `path.<keep>` (oldest). Delete first, then rename in
/// order.
pub type Plan {
  Plan(delete: List(String), rename: List(#(String, String)))
}

pub fn plan(path: String, keep: Int) -> Plan {
  case keep <= 0 {
    True -> Plan(delete: [path], rename: [])
    False -> {
      let renames =
        list.repeat(Nil, keep - 1)
        |> list.index_map(fn(_, i) { keep - 1 - i })
        |> list.map(fn(n) { #(numbered(path, n), numbered(path, n + 1)) })
      Plan(
        delete: [numbered(path, keep)],
        rename: list.append(renames, [#(path, numbered(path, 1))]),
      )
    }
  }
}

fn numbered(path: String, n: Int) -> String {
  path <> "." <> int.to_string(n)
}

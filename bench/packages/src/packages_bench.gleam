import argv
import bench/cpu
import bench/services
import gleam/list

/// `gleam run` for everything, or name suites: `gleam run -- cpu services`.
pub fn main() -> Nil {
  let suites = case argv.load().arguments {
    [] -> ["cpu", "services"]
    names -> names
  }
  list.each(suites, fn(suite) {
    case suite {
      "cpu" -> cpu.run()
      "services" -> services.run()
      _ -> Nil
    }
  })
}

// sdk/src/examples/git_clone.gleam
//
// Clone a Git repository over HTTPS and inspect its contents.
//
// Run with:
//   dgl generate
//   gleam run -m examples/git_clone

import dagger
import dagger/dsl/dag
import dagger/dsl/directory as dir
import dagger/dsl/git
import gleam/io
import gleam/string

pub fn main() {
  use client <- dagger.connect()

  // Clone the Gleam repository at a specific tag — no git binary needed,
  // Dagger handles the fetch natively.
  let repo =
    dag.git("https://github.com/gleam-lang/gleam.git", with: dag.none)
    |> git.tag("v1.14.0")
    |> git.tree(with: git.none)

  use result <- dir.entries(repo, dir.none, client)
  case result {
    Ok(entries) -> {
      io.println("Repository root contents:")
      entries
      |> string.join("\n")
      |> io.println
    }
    Error(e) -> io.println_error("Pipeline failed: " <> string.inspect(e))
  }
}

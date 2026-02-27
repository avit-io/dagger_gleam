// sdk/src/examples/clone_repository.gleam
//
// Clone a remote Git repository into a container and list its contents.
//
// Run with:
//   dgl generate
//   dagger run gleam run -m examples/clone_repository

import dagger
import dagger/dsl/container as c
import gleam/io
import gleam/string

pub fn main() {
  use client <- dagger.connect()

  // Clone a public repo and list files at the root
  let pipeline =
    c.container(with: fn(o) { o |> c.opt_platform("linux/amd64") })
    |> c.from("alpine/git:v2.49.1")
    |> c.with_exec(
      [
        "git", "clone", "--depth=1", "https://github.com/gleam-lang/gleam.git",
        "/repo",
      ],
      with: c.none,
    )
    |> c.with_exec(["ls", "/repo"], with: c.none)

  use result <- c.stdout(pipeline, client)

  case result {
    Ok(out) -> {
      io.println("Repository contents:")
      io.println(string.trim(out))
    }
    Error(e) -> io.println_error("Pipeline failed: " <> string.inspect(e))
  }
}

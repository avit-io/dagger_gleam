// sdk/src/examples/basic_pipeline.gleam
//
// Basic pipeline example: runs a container and prints a greeting from Lucy ⭐
//
// Run with:
//   dgl generate
//   gleam run -m examples/basic_pipeline

import dagger
import dagger/dsl/container as c
import gleam/io
import gleam/string

pub fn main() {
  use client <- dagger.connect()

  let pipeline =
    c.container(opts: [c.Platform("linux/amd64")])
    |> c.from("alpine:3.21")
    |> c.with_exec(
      ["echo", "Hello from Lucy! ⭐ Gleam pipelines are just data."],
      opts: [],
    )

  use result <- c.stdout(pipeline, client)

  case result {
    Ok(out) -> io.println(string.trim(out))
    Error(e) -> io.println_error("Pipeline failed: " <> string.inspect(e))
  }
}

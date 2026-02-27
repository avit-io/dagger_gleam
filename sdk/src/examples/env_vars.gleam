// sdk/src/examples/env_vars.gleam
//
// Set environment variables in a container and read them back.
//
// Run with:
//   dgl generate
//   dagger run --progress="plain" gleam run -m examples/env_vars

import dagger
import dagger/dsl/container as c
import gleam/io
import gleam/string

pub fn main() {
  use client <- dagger.connect()

  let pipeline =
    c.container(with: fn(o) { o |> c.opt_platform("linux/amd64") })
    |> c.from("alpine:3.21")
    |> c.with_env_variable("APP_ENV", "production", with: c.none)
    |> c.with_env_variable("APP_VERSION", "1.0.0", with: c.none)
    |> c.with_env_variable("APP_NAME", "my-gleam-app", with: c.none)
    |> c.with_exec(
      [
        "sh",
        "-c",
        "echo APP_ENV=$APP_ENV APP_VERSION=$APP_VERSION APP_NAME=$APP_NAME",
      ],
      with: c.none,
    )

  use result <- c.stdout(pipeline, client)
  case result {
    Ok(out) -> io.println(string.trim(out))
    Error(e) -> io.println_error("Pipeline failed: " <> string.inspect(e))
  }
}

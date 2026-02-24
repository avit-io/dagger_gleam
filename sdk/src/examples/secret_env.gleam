// sdk/src/examples/secret_env.gleam
//
// Pass a secret as an environment variable into a container without
// ever exposing its value in logs or the Dagger cache.
//
// Run with:
//   dgl generate
//   MY_TOKEN=supersecret dagger run --progress="plain" gleam run -m examples/secret_env

import dagger
import dagger/dsl/container as c
import dagger/dsl/dag
import dagger/dsl/types as t
import envoy
import gleam/io
import gleam/string

pub fn main() {
  use client <- dagger.connect()

  // Read the secret value from the environment — never hardcode it.
  let token = case envoy.get("MY_TOKEN") {
    Ok(val) -> val
    Error(_) -> {
      io.println_error("MY_TOKEN not set")
      panic
    }
  }

  // Wrap the plaintext value in a Dagger Secret.
  // From this point on Dagger treats it as opaque — it will never appear
  // in query logs, pipeline output, or the cache layer.
  let secret: t.Secret = dag.set_secret("my_token", token)

  // Mount the secret as an env var inside the container.
  let pipeline =
    c.container(opts: [c.Platform("linux/amd64")])
    |> c.from("alpine:3.21")
    |> c.with_secret_variable("MY_TOKEN", secret)
    |> c.with_exec(
      // Dagger masks the real value in logs — only the length leaks.
      ["sh", "-c", "echo \"Token length: $(echo $MY_TOKEN | wc -c)\""],
      opts: [],
    )

  use result <- c.stdout(pipeline, client)
  case result {
    Ok(out) -> io.println(string.trim(out))
    Error(e) -> io.println_error("Pipeline failed: " <> string.inspect(e))
  }
}

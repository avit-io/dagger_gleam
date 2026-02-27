# dagger_gleam

> **Note:** This package is in early development. The API may change before 1.0.

**Type-safe Dagger pipelines in Gleam.**

[Dagger](https://dagger.io) lets you define CI/CD pipelines as code, running them in containers with full caching and reproducibility. `dagger_gleam` brings that to Gleam with a generated, type-safe DSL and a functional execution model: you build a description of your pipeline first, then execute it — no hidden side effects.

---

## Installation

```sh
gleam add dagger_gleam
```

The DSL modules (`dagger/dsl/container`, `dagger/dsl/git`, …) are pre-generated from Dagger's GraphQL schema and included in the package. No code generation step required for users.

---

## Quick Start

```gleam
import dagger
import dagger/dsl/container as c
import dagger/dsl/host as h
import gleam/io
import gleam/string

pub fn main() {
  use client <- dagger.connect()

  let src = h.host() |> h.directory(".", with: h.none)

  let pipeline =
    c.container(with: fn(o) { o |> c.opt_platform("linux/amd64") })
    |> c.from("ghcr.io/gleam-lang/gleam:v1.14.0-erlang")
    |> c.with_mounted_directory("/src", src, with: c.none)
    |> c.with_workdir("/src", with: c.none)
    |> c.with_exec(["gleam", "test"], with: c.none)

  use result <- c.stdout(pipeline, client)
  case result {
    Ok(out) -> io.println(string.trim(out))
    Error(e) -> io.println_error(string.inspect(e))
  }
}
```

Run it with:

```sh
dagger run gleam run
```

---

## The `with:` API

Every DSL function that accepts optional arguments takes a `with:` builder:

```gleam
// no options
c.with_exec(["gleam", "test"], with: c.none)

// one option
c.with_exec(["gleam", "test"], with: fn(o) { o |> c.expand(True) })

// multiple options
c.with_exec(["gleam", "test"], with: fn(o) {
  o |> c.expand(True) |> c.skip_entrypoint(True)
})
```

`c.none` is just the identity function — use it whenever you have nothing to configure.

---

## Examples

The `examples/` directory in the [source repository](https://github.com/avit-io/dagger_gleam) contains runnable examples:

| Module | What it shows |
|---|---|
| `examples/basic_pipeline` | Hello world — run a command in a container |
| `examples/env_vars` | Set and read environment variables |
| `examples/secret_env` | Pass secrets without exposing them in logs |
| `examples/clone_repository` | Clone a git repo via a container |
| `examples/git_clone` | Clone a repo using Dagger's native git support |

---

## How It Works

`dagger.connect` opens a connection to the Dagger engine and passes a `Client` to your callback. DSL calls build a lazy operation tree — nothing is sent over the wire until you call a terminal function (`stdout`, `export`, `entries`, …). The interpreter then resolves any deferred values (e.g. local directory IDs) and executes a single GraphQL query.

---

## Source & Contributing

[github.com/avit-io/dagger_gleam](https://github.com/avit-io/dagger_gleam)

Issues and PRs are welcome. Active development happens on the `dev` branch.

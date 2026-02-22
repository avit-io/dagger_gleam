import dagger
import dagger/dsl/container as c
import dagger/dsl/host as h
import gleam/io
import gleam/string
import gleeunit/should

pub fn print_gleam_version_test() {
  use client <- dagger.connect()

  let cmd =
    c.container(opts: [c.Platform("linux/amd64")])
    |> c.from("ghcr.io/gleam-lang/gleam:v1.14.0-erlang")
    |> c.with_exec(["gleam", "--version"], opts: [])

  use result <- c.stdout(cmd, client)

  case result {
    Ok(out) -> {
      io.println("Dagger dice: " <> out)
      out |> string.contains("1.14.0") |> should.be_true()
    }
    Error(e) -> {
      io.println_error(string.inspect(e))
      should.fail()
    }
  }
}

pub fn load_local_directory_test() {
  use client <- dagger.connect()

  let cmd =
    c.container(opts: [c.Platform("linux/amd64")])
    |> c.from("alpine:3.21")
    |> c.with_mounted_directory("/src", h.host() |> h.directory("", []), [])
    |> c.with_exec(["ls"], opts: [])

  use result <- c.stdout(cmd, client)

  case result {
    Ok(out) -> {
      io.println("Dagger dice: " <> out)
    }
    Error(e) -> {
      io.println_error(string.inspect(e))
      should.fail()
    }
  }
}

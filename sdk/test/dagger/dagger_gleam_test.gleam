import dagger
import dagger/dsl/container as c
import dagger/dsl/host as h
import dagger/types.{ExecutionError}
import gleam/io
import gleam/string
import gleeunit/should

pub fn print_gleam_version_test() {
  use client <- dagger.connect()

  let cmd =
    c.container(with: fn(o) { o |> c.opt_platform("linux/amd64") })
    |> c.from("ghcr.io/gleam-lang/gleam:v1.14.0-erlang")
    |> c.with_exec(["gleam", "--version"], with: c.none)

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
    c.container(with: fn(o) { o |> c.opt_platform("linux/amd64") })
    |> c.from("alpine:3.21")
    |> c.with_mounted_directory("/src", h.host() |> h.directory("", h.none), c.none)
    |> c.with_exec(["ls"], with: c.none)

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

pub fn exit_code_error_test() {
  use client <- dagger.connect()
  let cmd =
    c.container(with: fn(o) { o |> c.opt_platform("linux/amd64") })
    |> c.from("alpine:3.21")
    |> c.with_exec(["sh", "-c", "exit 1"], with: c.none)

  use result <- c.stdout(cmd, client)
  case result {
    Ok(_) -> should.fail()
    Error(e) -> {
      case e {
        ExecutionError(_) -> {
          io.println("Correttamente catturato ExecutionError")
          should.be_true(True)
        }
        _ -> {
          io.println_error("Errore sbagliato: " <> string.inspect(e))
          should.fail()
        }
      }
    }
  }
}

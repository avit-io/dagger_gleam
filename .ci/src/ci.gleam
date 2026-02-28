import dagger
import dagger/dsl/container as c
import dagger/dsl/dag
import dagger/dsl/directory as d
import dagger/dsl/host as h
import dagger/dsl/types as t
import envoy
import gleam/int
import gleam/io
import gleam/result
import gleam/string

const gleam_image = "ghcr.io/gleam-lang/gleam:v1.14.0-erlang"

pub fn main() {
  use client <- dagger.connect()

  let project =
    h.host()
    |> h.directory("..", with: fn(o) {
      o |> h.opt_exclude(["**/.git", "**/build"])
    })

  let dist =
    c.container(with: fn(o) { o |> c.opt_platform("linux/amd64") })
    |> c.from(gleam_image)
    |> c.with_mounted_directory("/app", project, with: c.none)
    |> codegen_step()
    |> build_step()
    |> test_step()
    |> package_step()
    |> c.directory(path: "/dist", with: c.none)

  use export_result <- d.export(dist, path: "./dist", with: d.none, client: client)
  use exported_path <- result.try(export_result)

  io.println("Package Hex pronto in: " <> exported_path)
  publish_step(project, client)
}

fn publish_step(project: t.Directory, client: dagger.Client) {
  case envoy.get("HEXPM_API_KEY") {
    Error(_) -> {
      io.println("HEXPM_API_KEY non impostata — skip pubblicazione")
      Ok(Nil)
    }
    Ok(api_key) -> {
      let secret: t.Secret = dag.set_secret("hexpm_api_key", api_key)

      let publisher =
        c.container(with: fn(o) { o |> c.opt_platform("linux/amd64") })
        |> c.from(gleam_image)
        |> c.with_mounted_directory("/app", project, with: c.none)
        |> c.with_workdir("/app/sdk", with: c.none)
        |> c.with_exec(["gleam", "deps", "download"], with: c.none)
        |> c.with_secret_variable("HEXPM_API_KEY", secret)
        |> c.with_exec(
          ["sh", "-c", "echo 'I am not using semantic versioning' | gleam publish --yes"],
          with: c.none,
        )

      use result <- c.stdout(publisher, client)
      case result {
        Ok(out) -> {
          io.println(out)
          Ok(Nil)
        }
        Error(e) -> {
          io.println_error("Pubblicazione fallita: " <> string.inspect(e))
          Error(e)
        }
      }
    }
  }
}

fn codegen_step(ctr: t.Container) -> t.Container {
  ctr
  |> c.with_workdir("/app/codegen", with: c.none)
  |> c.with_exec(["gleam", "deps", "download"], with: c.none)
  |> c.with_exec(["gleam", "run"], with: c.none)
}

fn build_step(ctr: t.Container) -> t.Container {
  ctr
  |> c.with_workdir("/app/sdk", with: c.none)
  |> c.with_exec(["gleam", "deps", "download"], with: c.none)
  |> c.with_exec(["gleam", "build"], with: c.none)
}

fn test_step(ctr: t.Container) -> t.Container {
  // La sessione Dagger gira sull'host a 127.0.0.1:PORT — inaccessibile
  // dall'interno di un container. La esponiamo come Dagger Service e la
  // bindiamo al container: gleam test si connette allo stesso engine già
  // in esecuzione, senza inception.
  let session_port = envoy.get("DAGGER_SESSION_PORT") |> result.unwrap("8080")
  let session_token = envoy.get("DAGGER_SESSION_TOKEN") |> result.unwrap("")
  let port_int = int.parse(session_port) |> result.unwrap(8080)

  let session_service =
    h.host()
    |> h.service(
      ports: [
        t.PortForward(
          frontend: port_int,
          backend: port_int,
          protocol: t.NetworkProtocolTcp,
        ),
      ],
      with: h.none,
    )

  ctr
  |> c.with_service_binding("dagger-session", session_service)
  |> c.with_env_variable("DAGGER_SESSION_HOST", "dagger-session", with: c.none)
  |> c.with_env_variable("DAGGER_SESSION_PORT", session_port, with: c.none)
  |> c.with_env_variable("DAGGER_SESSION_TOKEN", session_token, with: c.none)
  |> c.with_exec(["gleam", "test"], with: c.none)
}

fn package_step(ctr: t.Container) -> t.Container {
  ctr
  |> c.with_exec(["gleam", "export", "hex-tarball"], with: c.none)
  |> c.with_exec(["sh", "-c", "mkdir -p /dist && mv build/*.tar /dist/"], with: c.none)
}

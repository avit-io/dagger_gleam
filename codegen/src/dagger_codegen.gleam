import dagger/runner.{DecodeError, FileError, run}
import envoy
import gleam/io
import gleam/result
import simplifile

const default_schema = "src/dagger/schema.generated.json"

const default_output = "../sdk/src/dagger/dsl"

pub fn main() {
  let schema =
    envoy.get("CODEGEN_SCHEMA") |> result.unwrap(default_schema)
  let output =
    envoy.get("CODEGEN_OUTPUT") |> result.unwrap(default_output)

  io.println("Generazione SDK: " <> schema <> " → " <> output)
  case run(schema, output) {
    Ok(_) -> io.println("Generato in: " <> output)
    Error(FileError(err)) ->
      io.println("Errore file: " <> simplifile.describe_error(err))
    Error(DecodeError(msg)) -> io.println("Errore parsing: " <> msg)
  }
}

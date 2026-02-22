// codegen/runner.gleam
import dagger/printer
import dagger/schema_decoder
import gleam/list
import gleam/option
import gleam/result
import simplifile

pub type CodegenError {
  FileError(simplifile.FileError)
  DecodeError(String)
}

pub fn run(input_path: String, output_dir: String) -> Result(Nil, CodegenError) {
  use json_schema <- result.try(
    simplifile.read(input_path)
    |> result.map_error(FileError),
  )

  use #(query_type_name, type_defs) <- result.try(
    schema_decoder.decode_schema(json_schema)
    |> result.map_error(fn(_) { DecodeError("schema non valido") }),
  )

  use _ <- result.try(
    simplifile.create_directory_all(output_dir)
    |> result.map_error(FileError),
  )

  printer.files_to_generate(type_defs, query_type_name)
  |> list.map(fn(pair) {
    let #(filename, content) = pair
    simplifile.write(output_dir <> "/" <> filename, content)
    |> result.map_error(FileError)
  })
  |> result.all
  |> result.map(fn(_) { Nil })
}

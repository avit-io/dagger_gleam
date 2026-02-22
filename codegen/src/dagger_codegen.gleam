import dagger/runner.{DecodeError, FileError, run}
import gleam/io
import simplifile

type Size {
  Standard
  Simplified
}

fn schema_path(size: Size) -> String {
  case size {
    Standard -> "src/dagger/schema.generated.json"
    Simplified -> "/tmp/test_schema.json"
  }
}

pub fn main() {
  io.println("🚀 Avvio generazione SDK...")
  case run(schema_path(Standard), "../sdk/src/dagger/dsl") {
    Ok(_) -> io.println("✨ src/dagger/generated aggiornato!")
    Error(FileError(err)) ->
      io.println("❌ Errore file: " <> simplifile.describe_error(err))
    Error(DecodeError(msg)) -> io.println("❌ Errore parsing: " <> msg)
  }
}

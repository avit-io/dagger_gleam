import envoy
import gleam/io
import gleam/result

pub type LogEntry {
  Debug(msg: String)
  Query(sql: String)
  Info(msg: String)
}

pub fn report(entry: LogEntry) -> Nil {
  // Recuperiamo il livello, se non c'è usiamo una stringa vuota
  let log_level = envoy.get("DAGGER_LOG_LEVEL") |> result.unwrap("")

  case entry {
    Debug(msg) ->
      case log_level {
        "debug" -> io.println("[dagger:debug] " <> msg)
        _ -> Nil
      }

    Query(sql) ->
      case log_level {
        "debug" | "query" -> io.println("\n🚀 DAGGER QUERY:\n" <> sql <> "\n---")
        _ -> Nil
      }

    Info(msg) ->
      case log_level {
        "silent" -> Nil
        _ -> io.println("[dagger:info] " <> msg)
      }
  }
}

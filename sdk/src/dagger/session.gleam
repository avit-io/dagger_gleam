import dagger/types.{type Client}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/result

// Tipo opaco per la Port Erlang — usato solo internamente.
type Port

type SessionHandle {
  SessionHandle(port: Port, client: Client)
}

@external(erlang, "dagger_session_ffi", "open_session")
fn ffi_open_session(
  command: String,
) -> Result(#(Port, String), String)

@external(erlang, "dagger_session_ffi", "close_session")
fn ffi_close_session(port: Port) -> Nil

/// Avvia `dagger session`, aspetta il JSON di connessione, esegue
/// la callback con il Client e chiude la sessione al termine.
pub fn with_session(callback: fn(Client) -> a) -> Result(a, String) {
  use handle <- open()
  Ok(callback(handle.client))
}

fn open(callback: fn(SessionHandle) -> Result(a, String)) -> Result(a, String) {
  use #(port, json_line) <- result.try(ffi_open_session("dagger session"))
  use client <- result.try(parse_session_json(json_line))
  let result = callback(SessionHandle(port: port, client: client))
  ffi_close_session(port)
  result
}

fn parse_session_json(json_str: String) -> Result(Client, String) {
  // dagger session emette: {"port":N,"session_token":"..."}
  // `host` non è presente → default 127.0.0.1
  let decoder = {
    use port <- decode.field("port", decode.int)
    use token <- decode.field("session_token", decode.string)
    let endpoint = "http://127.0.0.1:" <> int.to_string(port) <> "/query"
    decode.success(types.Client(endpoint: endpoint, token: token))
  }
  json.parse(json_str, decoder)
  |> result.map_error(fn(e) {
    "Failed to decode dagger session JSON: " <> json_str <> " — " <> string_of_json_error(e)
  })
}

fn string_of_json_error(e: json.DecodeError) -> String {
  case e {
    json.UnexpectedEndOfInput -> "unexpected end of input"
    json.UnexpectedByte(b) -> "unexpected byte: " <> b
    json.UnexpectedSequence(s) -> "unexpected sequence: " <> s
    json.UnableToDecode(_) -> "unable to decode"
  }
}

import dagger/types.{
  type Client, type GraphQLError, type QueryError, type Try, Client,
  DecodingError, ExecutionError, GraphQLError, NetworkError,
}
import envoy
import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/http/request
import gleam/httpc
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string

//pub fn new(endpoint: String, token: String) -> Client {
//  Client(endpoint: endpoint, token: token)
//}

fn graphql_error_decoder() -> decode.Decoder(GraphQLError) {
  use message <- decode.field("message", decode.string)
  use path <- decode.field("path", decode.list(decode.dynamic))
  decode.success(GraphQLError(message: message, path: path))
}

fn check_graphql_errors(
  dyn: dynamic.Dynamic,
) -> Result(dynamic.Dynamic, QueryError) {
  case
    decode.run(dyn, decode.at(["errors"], decode.list(graphql_error_decoder())))
  {
    Ok(errors) -> Error(ExecutionError(errors))
    Error(_) -> Ok(dyn)
  }
}

pub fn connect(callback: fn(Client) -> a) -> a {
  // Recuperiamo la porta con un default (Dagger di solito usa porte dinamiche,
  // ma per i test locali spesso si usa la 8080 o simili)
  let port = envoy.get("DAGGER_SESSION_PORT") |> result.unwrap("8080")

  // Recuperiamo il token
  let token = envoy.get("DAGGER_SESSION_TOKEN") |> result.unwrap("")

  // Costruiamo l'endpoint completo
  let endpoint = "http://127.0.0.1:" <> port <> "/query"

  // Creiamo il record Client
  let client = types.Client(endpoint: endpoint, token: token)

  // Passiamo il client alla funzione dell'utente
  callback(client)
}

pub fn raw_query(client: Client, query_string: String) -> Try(dynamic.Dynamic) {
  // --- AGGIUNGI QUESTO ---
  io.println("\n🚀 INVIO QUERY GRAPHQL:")
  io.println(query_string)
  io.println("------------------------\n")
  // ------------------------

  let body = json.object([#("query", json.string(query_string))])
  let auth =
    bit_array.base64_encode(bit_array.from_string(client.token <> ":"), True)
  let assert Ok(req) = request.to(client.endpoint)
  let res =
    req
    |> request.set_method(Post)
    |> request.set_header("Authorization", "Basic " <> auth)
    |> request.set_header("Content-type", "application/json")
    |> request.set_body(json.to_string(body))
    |> httpc.send()
  case res {
    Ok(resp) if resp.status == 200 ->
      json.parse(resp.body, decode.dynamic)
      |> result.map_error(fn(_) { DecodingError("JSON invalido") })
      |> result.try(check_graphql_errors)
    Ok(resp) ->
      Error(NetworkError("Errore HTTP: " <> string.inspect(resp.status)))
    Error(err) -> Error(NetworkError("Errore Network: " <> string.inspect(err)))
  }
}

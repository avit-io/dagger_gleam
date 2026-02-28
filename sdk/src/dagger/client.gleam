import dagger/logger.{Query}
import dagger/session
import dagger/types.{
  type Client, type GraphQLError, type QueryError, type Try,
  DecodingError, ExecutionError, GraphQLError, NetworkError,
}
import envoy
import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/result
import gleam/string

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
  case envoy.get("DAGGER_SESSION_PORT") {
    // Modalità `dagger run`: le variabili sono già nell'env (es. CI/test step).
    Ok(port) -> {
      let token = envoy.get("DAGGER_SESSION_TOKEN") |> result.unwrap("")
      // DAGGER_SESSION_HOST permette di raggiungere la sessione da inside un
      // container (es. via service binding); default 127.0.0.1 per uso normale.
      let host = envoy.get("DAGGER_SESSION_HOST") |> result.unwrap("127.0.0.1")
      let endpoint = "http://" <> host <> ":" <> port <> "/query"
      let client = types.Client(endpoint: endpoint, token: token)
      callback(client)
    }
    // Modalità standalone: avvia `dagger session` direttamente.
    Error(_) -> {
      let assert Ok(result) = session.with_session(callback)
      result
    }
  }
}

pub fn raw_query(client: Client, query_string: String) -> Try(dynamic.Dynamic) {
  logger.report(Query(query_string))

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

import dagger/client as dagger_client
import dagger/logger.{Debug}
import dagger/types.{
  type Client, type DaggerOp, type Try, Fetch, Field, GDeferred, GList, GObject,
  GString, Pure,
}
import gleam/dynamic/decode
import gleam/list
import gleam/result

pub fn run(op: DaggerOp(Try(a)), client: Client) -> Try(a) {
  case op {
    Pure(result) -> result
    Fetch(fields, _decoder, next) -> {
      let resolved_fields = resolve_fields(fields, client)
      let query_string = types.serialize(resolved_fields)
      use dynamic_data <- result.try(dagger_client.raw_query(
        client,
        query_string,
      ))
      use _ <- result.try(check_errors(dynamic_data))
      let next_op = next(dynamic_data)
      run(next_op, client)
    }
  }
}

fn check_errors(dyn: decode.Dynamic) -> Result(Nil, types.QueryError) {
  let errors_decoder =
    decode.at(["errors"], decode.list(decode.at(["message"], decode.string)))
  case decode.run(dyn, errors_decoder) {
    Ok([_, ..] as msgs) ->
      Error(
        types.ExecutionError(
          list.map(msgs, fn(m) { types.GraphQLError(message: m, path: []) }),
        ),
      )
    _ -> Ok(Nil)
  }
}

fn resolve_fields(
  fields: List(types.Field),
  client: Client,
) -> List(types.Field) {
  list.map(fields, fn(field) {
    Field(
      ..field,
      args: list.map(field.args, fn(arg) {
        #(arg.0, resolve_value(arg.1, client))
      }),
      subfields: resolve_fields(field.subfields, client),
    )
  })
}

fn resolve_value(val: types.Value, client: Client) -> types.Value {
  case val {
    GDeferred(op) -> {
      let id_op =
        types.bind(op, fn(fields) {
          Pure(list.append(fields, [Field("id", [], [])]))
        })
      case run_id_resolver(id_op, client) {
        Ok(id) -> GString(id)
        Error(_) -> panic as "Fallita risoluzione ID Dagger"
      }
    }
    GList(items) -> GList(list.map(items, resolve_value(_, client)))
    GObject(fields) ->
      GObject(list.map(fields, fn(f) { #(f.0, resolve_value(f.1, client)) }))
    _ -> val
  }
}

fn run_id_resolver(
  op: DaggerOp(List(types.Field)),
  client: Client,
) -> Result(String, types.QueryError) {
  let fields = types.get_query(op)
  let query_string = types.serialize(fields)
  logger.report(Debug("ID RESOLVER: " <> types.serialize(fields)))
  use dynamic_data <- result.try(dagger_client.raw_query(client, query_string))
  use _ <- result.try(check_errors(dynamic_data))
  let path = types.make_path(fields)
  decode.run(dynamic_data, decode.at(path, decode.string))
  |> result.map_error(fn(_) {
    types.DecodingError("Impossibile decodificare ID dall'oggetto")
  })
}

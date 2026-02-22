import dagger/client as dagger_client
import dagger/types.{
  type Client, type DaggerOp, type Try, Fetch, Field, GDeferred, GList, GObject,
  GString, Pure,
}
import gleam/dynamic/decode
import gleam/list
import gleam/result

pub fn run(op: DaggerOp(a), client: Client) -> Try(a) {
  case op {
    Pure(val) -> Ok(val)

    Fetch(fields, _decoder, next) -> {
      // --- NUOVO: Risoluzione dei Deferred ---
      // Prima di serializzare, scansioniamo i campi e risolviamo eventuali ID mancanti
      let resolved_fields = resolve_fields(fields, client)

      // Ora serializziamo i campi puliti (senza GDeferred)
      let query_string = types.serialize(resolved_fields)

      // Log di debug per vedere la query finale pulita
      // io.println("🚀 INVIO QUERY RISOLTA:\n" <> query_string)

      use dynamic_data <- result.try(dagger_client.raw_query(
        client,
        query_string,
      ))

      let next_op = next(dynamic_data)
      run(next_op, client)
    }
  }
}

// Funzione interna per scansionare i campi ricorsivamente
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

// Se trova un GDeferred, lancia una query sincrona per ottenere l'ID
fn resolve_value(val: types.Value, client: Client) -> types.Value {
  case val {
    GDeferred(op) -> {
      // Creiamo una query che punta al campo "id" dell'oggetto
      let id_op =
        types.bind(op, fn(fields) {
          // Aggiungiamo il campo "id" alla fine della selezione
          Pure(list.append(fields, [Field("id", [], [])]))
        })

      // Eseguiamo run ricorsivamente per ottenere l'ID.
      // Dagger restituisce l'ID come stringa nel campo "id".
      // Per estrarlo correttamente, dobbiamo assicurarci che id_op
      // sappia decodificare il JSON di ritorno.
      case run_id_resolver(id_op, client) {
        Ok(id) -> GString(id)
        Error(e) -> {
          // In produzione qui dovresti gestire l'errore meglio,
          // per ora il panic ci aiuta a capire se fallisce la risoluzione
          panic as "Fallita risoluzione ID Dagger"
        }
      }
    }
    GList(items) -> GList(list.map(items, resolve_value(_, client)))
    GObject(fields) ->
      GObject(list.map(fields, fn(f) { #(f.0, resolve_value(f.1, client)) }))
    _ -> val
  }
}

// Helper specifico per risolvere l'ID.
// Dagger restituisce sempre una stringa per il campo .id()
fn run_id_resolver(
  op: DaggerOp(List(types.Field)),
  client: Client,
) -> Result(String, types.QueryError) {
  let fields = types.get_query(op)
  let query_string = types.serialize(fields)

  use dynamic_data <- result.try(dagger_client.raw_query(client, query_string))

  // Estraiamo l'ID dal path. Dato che abbiamo aggiunto "id" in fondo,
  // usiamo make_path per trovare dove si trova nel JSON.
  let path = types.make_path(fields)

  decode.run(dynamic_data, decode.at(path, decode.string))
  |> result.map_error(fn(_) {
    types.DecodingError("Impossibile decodificare ID dall'oggetto")
  })
}

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/string

// --- TIPI CORE PER IL CLIENT E ERRORI ---

pub type Client {
  Client(endpoint: String, token: String)
}

pub type QueryError {
  NetworkError(String)
  DecodingError(String)
  ExecutionError(List(GraphQLError))
}

pub type GraphQLError {
  GraphQLError(message: String, path: List(Dynamic))
}

pub type Try(a) =
  Result(a, QueryError)

// --- LA MONADE DAGGER ---

pub type DaggerOp(a) {
  Pure(a)
  /// Fetch memorizza i campi, il decoder per il risultato e la continuazione.
  Fetch(
    fields: List(Field),
    decoder: decode.Decoder(Dynamic),
    next: fn(Dynamic) -> DaggerOp(a),
  )
}

pub fn pure(val: a) -> DaggerOp(a) {
  Pure(val)
}

pub fn bind(op: DaggerOp(a), callback: fn(a) -> DaggerOp(b)) -> DaggerOp(b) {
  case op {
    Pure(val) -> callback(val)
    Fetch(fields, decoder, next) -> {
      Fetch(fields: fields, decoder: decoder, next: fn(dyn) {
        bind(next(dyn), callback)
      })
    }
  }
}

pub fn continue(op: DaggerOp(a), callback: fn(a) -> DaggerOp(b)) -> DaggerOp(b) {
  case op {
    Pure(a) -> callback(a)
    Fetch(fields, decoder, next) ->
      Fetch(fields, decoder, fn(dyn) { continue(next(dyn), callback) })
  }
}

pub fn get_query(op: DaggerOp(List(Field))) -> List(Field) {
  case op {
    Pure(q) -> q
    Fetch(q, _, _) -> q
  }
}

// --- AST GRAPHQL ---

pub type Field {
  Field(name: String, args: List(#(String, Value)), subfields: List(Field))
}

pub type Value {
  GString(String)
  GInt(Int)
  GFloat(Float)
  GBool(Bool)
  GList(List(Value))
  GObject(List(#(String, Value)))
  GNull
  /// GDeferred permette di annidare un'operazione che restituisce una lista di campi
  /// (ovvero un oggetto Dagger come Directory o Container) come argomento.
  GDeferred(DaggerOp(List(Field)))
}

// --- UTILITY PER SERIALIZZAZIONE ---

pub fn make_path(fields: List(Field)) -> List(String) {
  let names = list.map(fields, fn(f) { f.name })
  ["data", ..names]
}

pub fn serialize(fields: List(Field)) -> String {
  let nested_fields = nest(fields)
  "{ " <> list.map(nested_fields, serialize_field) |> string.join(" ") <> " }"
}

fn serialize_field(field: Field) -> String {
  let args = case field.args {
    [] -> ""
    args -> "(" <> serialize_args(args) <> ")"
  }
  let subs = case field.subfields {
    [] -> ""
    subs -> " { " <> list.map(subs, serialize_field) |> string.join(" ") <> " }"
  }
  field.name <> args <> subs
}

fn serialize_args(args: List(#(String, Value))) -> String {
  args
  |> list.map(fn(arg) { arg.0 <> ": " <> serialize_value(arg.1) })
  |> string.join(", ")
}

fn serialize_value(value: Value) -> String {
  case value {
    GString(s) -> json.to_string(json.string(s))
    // gestisce tutti gli escape
    GInt(i) -> int.to_string(i)
    GFloat(f) -> float.to_string(f)
    GBool(True) -> "true"
    GBool(False) -> "false"
    GList(items) ->
      "[" <> list.map(items, serialize_value) |> string.join(", ") <> "]"
    GObject(fields) ->
      "{"
      <> list.map(fields, fn(f) { f.0 <> ": " <> serialize_value(f.1) })
      |> string.join(", ")
      <> "}"
    GNull -> "null"
    // Nota: GDeferred non deve essere serializzato direttamente.
    // L'interprete deve risolverlo in GString(id) prima della serializzazione finale.
    GDeferred(op) -> {
      let fields = get_query(op)
      // produce: setSecret(name: "my_token", plaintext: "***")
      // NON: { setSecret(...) }
      case nest(fields) {
        [field] -> serialize_field(field)
        // singolo campo radice
        _ -> panic as "GDeferred deve avere un solo campo radice"
      }
    }
  }
}

pub fn nest(fields: List(Field)) -> List(Field) {
  case list.reverse(fields) {
    [] -> []
    [last, ..rest] -> {
      list.fold(rest, last, fn(acc, f) {
        Field(name: f.name, args: f.args, subfields: [acc])
      })
      |> list.wrap
    }
  }
}

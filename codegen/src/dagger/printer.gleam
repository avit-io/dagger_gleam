// =============================================================================
// PRINTER - Genera codice Gleam dallo schema Dagger
// =============================================================================
// Struttura:
//   1. Import
//   2. Tipi pubblici (TypeClass)
//   3. Helper di classificazione
//   4. Helper di firma (join_sig, build_*_sig)
//   5. Helper di serializzazione GQL (type_ref_to_gql_value*)
//   6. Helper di decodifica (decode_for_type, generate_fetch_body, generate_fetch_list_body)
//   7. Helper di stampa tipi (print_type_ref*)
//   8. Helper di formattazione (to_snake_case, capitalize, escape_reserved, ...)
//   9. Generatori di argomenti (generate_args_sig, generate_gql_args)
//  10. Generatori di tipi (generate_enum_type, generate_input_to_json, ...)
//  11. Generatori di funzioni oggetto (generate_*_function)
//  12. Generatori di funzioni dag (generate_dag_*_function)
//  13. Entry point pubblico (files_to_generate)
// =============================================================================

import dagger/types.{
  type ArgDef, type FieldDef, type TypeDef, type TypeRef, AliasedDef, ArgDef,
  BoxDef, EnumDef, IgnoredDef, InputDef, ListOf, Named, NonNull, ObjectDef,
  ScalarDef,
}
import gleam/list
import gleam/option
import gleam/result
import gleam/string

// =============================================================================
// 2. TIPI PUBBLICI
// =============================================================================

pub type TypeClass {
  IsScalar
  IsEnum
  IsObject
  IsInput
}

// =============================================================================
// 3. HELPER DI CLASSIFICAZIONE
// =============================================================================

fn is_builtin(name: String) -> Bool {
  case name {
    "String" | "Int" | "Float" | "Bool" | "Nil" | "Boolean" -> True
    _ -> False
  }
}

fn classify_type(name: String, type_defs: List(TypeDef)) -> TypeClass {
  type_defs
  |> list.find_map(fn(td) {
    case td {
      ScalarDef(n, _) if n == name -> Ok(IsScalar)
      BoxDef(n, _) if n == name -> Ok(IsObject)
      EnumDef(n, _, _) if n == name -> Ok(IsEnum)
      ObjectDef(n, _, _) if n == name -> Ok(IsObject)
      InputDef(n, _, _) if n == name -> Ok(IsInput)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap(IsObject)
}

fn is_primitive(ref: TypeRef, type_defs: List(TypeDef)) -> Bool {
  case ref {
    Named(name) ->
      is_builtin(name) || classify_type(name, type_defs) == IsScalar
    NonNull(inner) -> is_primitive(inner, type_defs)
    ListOf(inner) -> is_primitive(inner, type_defs)
  }
}

fn is_terminal(ref: TypeRef, type_defs: List(TypeDef)) -> Bool {
  case ref {
    Named(name) ->
      is_builtin(name)
      || classify_type(name, type_defs) == IsScalar
      || classify_type(name, type_defs) == IsEnum
    NonNull(inner) -> is_terminal(inner, type_defs)
    ListOf(inner) -> is_terminal(inner, type_defs)
  }
}

fn is_list_of_object(ref: TypeRef, type_defs: List(TypeDef)) -> Bool {
  case ref {
    ListOf(inner) -> !is_primitive(inner, type_defs)
    NonNull(inner) -> is_list_of_object(inner, type_defs)
    _ -> False
  }
}

fn split_args(args: List(ArgDef)) -> #(List(ArgDef), List(ArgDef)) {
  list.partition(args, fn(arg) {
    case arg.type_ {
      NonNull(_) -> True
      _ -> False
    }
  })
}

fn get_return_type_name(ref: TypeRef) -> String {
  case ref {
    Named(name) -> name
    NonNull(inner) -> get_return_type_name(inner)
    ListOf(inner) -> get_return_type_name(inner)
  }
}

fn terminal_return_type(ref: TypeRef, type_defs: List(TypeDef)) -> String {
  let name = get_return_type_name(ref)
  case classify_type(name, type_defs) {
    IsScalar -> "String"
    _ -> print_type_ref(ref, type_defs)
  }
}

fn inner_type(ref: TypeRef) -> TypeRef {
  case ref {
    ListOf(inner) -> inner
    NonNull(inner) -> inner_type(inner)
    other -> other
  }
}

fn unique_args(args: List(ArgDef)) -> List(ArgDef) {
  list.fold(over: args, from: [], with: fn(acc, arg) {
    let ArgDef(name: name_to_check, ..) = arg
    let exists =
      list.any(acc, fn(a) {
        let ArgDef(name: existing_name, ..) = a
        existing_name == name_to_check
      })
    case exists {
      True -> acc
      False -> [arg, ..acc]
    }
  })
  |> list.reverse
}

fn get_query_fields(
  type_defs: List(TypeDef),
  query_type_name: String,
) -> List(FieldDef) {
  type_defs
  |> list.find_map(fn(td) {
    case td {
      ObjectDef(name, _, fields) if name == query_type_name -> Ok(fields)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap([])
}

fn get_query_args_for_type(
  target_name: String,
  query_fields: List(FieldDef),
) -> List(ArgDef) {
  query_fields
  |> list.filter(fn(f) { get_return_type_name(f.return_type) == target_name })
  |> list.flat_map(fn(f) { f.arguments })
}

fn get_query_field_for_type(
  target_name: String,
  query_fields: List(FieldDef),
) -> option.Option(FieldDef) {
  list.find(query_fields, fn(f) {
    get_return_type_name(f.return_type) == target_name
  })
  |> option.from_result
}

fn resolve_box(name: String, type_defs: List(TypeDef)) -> String {
  list.find_map(type_defs, fn(td) {
    case td {
      BoxDef(n, target) if n == name -> Ok(target)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap(name)
}

fn get_variant_name(arg: ArgDef, all_opts: List(ArgDef)) -> String {
  let same_name_args = list.filter(all_opts, fn(a) { a.name == arg.name })

  case list.length(same_name_args) {
    1 -> capitalize(arg.name)
    _ -> capitalize(arg.name) <> capitalize(get_return_type_name(arg.type_))
  }
}

// =============================================================================
// 4. HELPER DI FIRMA
// =============================================================================

// Unica fonte di verità per la gestione delle virgole nelle firme.
// Filtra le parti vuote e le unisce con ", ".
fn join_sig(parts: List(String)) -> String {
  parts
  |> list.filter(fn(p) { p != "" })
  |> string.join(", ")
}

fn build_client_sig() -> String {
  "client client: Client"
}

// "arg1 arg1: Type1, arg2 arg2: Type2" — vuoto se nessun required.
// Scalari presentati come String all'utente.
fn build_required_sig(
  required: List(ArgDef),
  type_defs: List(TypeDef),
) -> String {
  required
  |> list.map(fn(arg) {
    let type_name = get_return_type_name(arg.type_)
    let t = case classify_type(type_name, type_defs) {
      IsScalar -> "String"
      _ -> print_type_ref(arg.type_, type_defs)
    }
    to_snake_case(arg.name) <> " " <> to_snake_case(arg.name) <> ": " <> t
  })
  |> string.join(", ")
}

fn build_opts_sig(optional: List(ArgDef), opt_type: String) -> String {
  case optional {
    [] -> ""
    _ -> "opts opts: List(" <> opt_type <> ")"
  }
}

// Firma CPS completa: args..., opts?, client, then handler: fn(Try(R)) -> a
fn build_cps_sig(
  required: List(ArgDef),
  optional: List(ArgDef),
  return_type: String,
  type_defs: List(TypeDef),
) -> String {
  join_sig([
    build_required_sig(required, type_defs),
    build_opts_sig(optional, "Opt"),
    build_client_sig(),
    "then handler: fn(Try(" <> return_type <> ")) -> a",
  ])
}

// =============================================================================
// 5. HELPER DI SERIALIZZAZIONE GQL
// =============================================================================

fn type_ref_to_gql_value(
  var_name: String,
  ref: TypeRef,
  type_defs: List(TypeDef),
) -> String {
  case ref {
    NonNull(inner) -> type_ref_to_gql_value(var_name, inner, type_defs)
    ListOf(inner) ->
      "types.GList(list.map("
      <> var_name
      <> ", fn(x) { "
      <> type_ref_to_gql_value("x", inner, type_defs)
      <> " }))"
    Named(name) ->
      case name {
        "String" -> "types.GString(" <> var_name <> ")"
        "Int" -> "types.GInt(" <> var_name <> ")"
        "Float" -> "types.GFloat(" <> var_name <> ")"
        "Bool" -> "types.GBool(" <> var_name <> ")"
        _ ->
          case classify_type(name, type_defs) {
            IsObject -> "types.GDeferred(" <> var_name <> ".op)"
            IsEnum ->
              "types.GString(t."
              <> to_snake_case(name)
              <> "_to_json("
              <> var_name
              <> "))"
            IsInput ->
              "types.GObject(t."
              <> to_snake_case(name)
              <> "_to_json("
              <> var_name
              <> "))"
            IsScalar -> "types.GString(" <> var_name <> ")"
            _ -> "types.GString(" <> var_name <> ")"
          }
      }
  }
}

// Versione locale: usata dentro types.gleam dove non c'è il prefisso t.
fn type_ref_to_gql_value_local(
  var_name: String,
  ref: TypeRef,
  type_defs: List(TypeDef),
) -> String {
  case ref {
    NonNull(inner) -> type_ref_to_gql_value_local(var_name, inner, type_defs)
    ListOf(inner) ->
      "types.GList(list.map("
      <> var_name
      <> ", fn(x) { "
      <> type_ref_to_gql_value_local("x", inner, type_defs)
      <> " }))"
    Named(name) ->
      case name {
        "String" -> "types.GString(" <> var_name <> ")"
        "Int" -> "types.GInt(" <> var_name <> ")"
        "Float" -> "types.GFloat(" <> var_name <> ")"
        "Bool" -> "types.GBool(" <> var_name <> ")"
        _ ->
          case classify_type(name, type_defs) {
            IsEnum ->
              "types.GString("
              <> to_snake_case(name)
              <> "_to_json("
              <> var_name
              <> "))"
            IsInput ->
              "types.GObject("
              <> to_snake_case(name)
              <> "_to_json("
              <> var_name
              <> "))"
            IsScalar -> "types.GString(" <> var_name <> ")"
            _ -> "types.GString(" <> var_name <> ")"
          }
      }
  }
}

// =============================================================================
// 6. HELPER DI DECODIFICA
// =============================================================================

fn decode_for_type(ref: TypeRef, type_defs: List(TypeDef)) -> String {
  case ref {
    Named("String") -> "decode.string"
    Named("Int") -> "decode.int"
    Named("Float") -> "decode.float"
    Named("Bool") -> "decode.bool"
    Named("Nil") -> "decode.dynamic"
    Named(name) ->
      case classify_type(name, type_defs) {
        IsEnum ->
          "decode.map(decode.string, fn(s) { t."
          <> to_snake_case(name)
          <> "_from_string(s) })"
        _ -> "decode.string"
      }
    NonNull(inner) -> decode_for_type(inner, type_defs)
    ListOf(inner) -> "decode.list(" <> decode_for_type(inner, type_defs) <> ")"
  }
}

// Blocco Fetch per terminal function.
// query_expr: espressione Gleam che produce DaggerOp(List(Field))
fn generate_fetch_body(
  field_name: String,
  query_expr: String,
  ref: TypeRef,
  type_defs: List(TypeDef),
) -> String {
  let decoder = decode_for_type(ref, type_defs)
  let base = inner_type(ref)
  let pure_val = case base {
    Named("Nil") -> "types.Pure(Nil)"
    _ -> "types.Pure(val)"
  }
  "  let op = {\n"
  <> "    use q <- types.bind("
  <> query_expr
  <> ")\n"
  <> "    let full_query = list.append(q, [field])\n"
  <> "    types.Fetch(\n"
  <> "      fields: full_query,\n"
  <> "      decoder: decode.dynamic,\n"
  <> "      next: fn(dyn) {\n"
  <> "        let path = types.make_path(full_query)\n"
  <> "        case decode.run(dyn, decode.at(path, "
  <> decoder
  <> ")) {\n"
  <> "          Ok(val) -> "
  <> pure_val
  <> "\n"
  <> "          Error(_) -> panic as \"Decoding error in "
  <> field_name
  <> "\"\n"
  <> "        }\n"
  <> "      }\n"
  <> "    )\n"
  <> "  }\n"
}

// Blocco Fetch per selection function (lista di oggetti).
fn generate_fetch_list_body(
  field_name: String,
  query_expr: String,
  inner_constructor: String,
) -> String {
  "  let op = {\n"
  <> "    use q <- types.bind("
  <> query_expr
  <> ")\n"
  <> "    let full_query = list.append(q, [field])\n"
  <> "    types.Fetch(\n"
  <> "      fields: full_query,\n"
  <> "      decoder: decode.dynamic,\n"
  <> "      next: fn(dyn) {\n"
  <> "        let path = types.make_path(full_query)\n"
  <> "        case decode.run(dyn, decode.at(path, decode.list(decode.dynamic))) {\n"
  <> "          Ok(items) -> types.Pure(list.map(items, fn(_) { "
  <> inner_constructor
  <> " }))\n"
  <> "          Error(_) -> panic as \"Decoding error in "
  <> field_name
  <> "\"\n"
  <> "        }\n"
  <> "      }\n"
  <> "    )\n"
  <> "  }\n"
}

// =============================================================================
// 7. HELPER DI STAMPA TIPI
// =============================================================================

pub fn print_type_ref(ref: TypeRef, type_defs: List(TypeDef)) -> String {
  case ref {
    Named(name) -> {
      let unboxed =
        list.find_map(type_defs, fn(td) {
          case td {
            BoxDef(n, target) if n == name -> Ok(target)
            _ -> Error(Nil)
          }
        })
      case unboxed {
        Ok(target) -> "t." <> target
        Error(Nil) ->
          case is_builtin(name) {
            True -> name
            False -> "t." <> name
          }
      }
    }
    NonNull(inner) -> print_type_ref(inner, type_defs)
    ListOf(inner) -> "List(" <> print_type_ref(inner, type_defs) <> ")"
  }
}

fn print_type_ref_local(ref: TypeRef, type_defs: List(TypeDef)) -> String {
  case ref {
    Named(name) -> {
      let unboxed =
        list.find_map(type_defs, fn(td) {
          case td {
            BoxDef(n, inner) if n == name -> Ok(inner)
            _ -> Error(Nil)
          }
        })
      case unboxed {
        Ok(inner) -> inner
        Error(Nil) -> name
      }
    }
    NonNull(inner) -> print_type_ref_local(inner, type_defs)
    ListOf(inner) -> "List(" <> print_type_ref_local(inner, type_defs) <> ")"
  }
}

// =============================================================================
// 8. HELPER DI FORMATTAZIONE
// =============================================================================

fn to_snake_case(name: String) -> String {
  let result =
    name
    |> string.to_graphemes
    |> list.flat_map(fn(c) {
      case c == string.uppercase(c) && c != string.lowercase(c) {
        True -> ["_", string.lowercase(c)]
        False -> [c]
      }
    })
    |> string.join("")
  case string.starts_with(result, "_") {
    True -> string.drop_start(result, 1)
    False -> result
  }
}

fn capitalize(name: String) -> String {
  case string.pop_grapheme(name) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> name
  }
}

fn escape_reserved(name: String) -> String {
  case name {
    "import" -> "import_"
    "type" -> "type_"
    "let" -> "let_"
    "case" -> "case_"
    "fn" -> "fn_"
    "pub" -> "pub_"
    "use" -> "use_"
    _ -> name
  }
}

fn format_description(desc: String) -> String {
  desc
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.map(fn(line) { "/// " <> line })
  |> string.join("\n")
}

fn fn_name_for(field: FieldDef) -> String {
  to_snake_case(field.name) |> escape_reserved
}

fn description_for(field: FieldDef) -> String {
  case field.description {
    option.None -> ""
    option.Some(d) -> format_description(d) <> "\n"
  }
}

// =============================================================================
// 9. GENERATORI DI ARGOMENTI
// =============================================================================

fn generate_args_sig(args: List(ArgDef), type_defs: List(TypeDef)) -> String {
  let #(required, optional) = split_args(args)
  join_sig([
    build_required_sig(required, type_defs),
    build_opts_sig(optional, "Opt"),
  ])
}

fn generate_gql_args(args: List(ArgDef), type_defs: List(TypeDef)) -> String {
  let #(required, optional) = split_args(args)

  // Gestiamo i required come stringa
  let req_fields_str =
    required
    |> list.map(fn(arg) {
      "#(\""
      <> arg.name
      <> "\", "
      <> type_ref_to_gql_value(to_snake_case(arg.name), arg.type_, type_defs)
      <> ")"
    })
    |> string.join(", ")
  let req_part = "[" <> req_fields_str <> "]"

  case optional {
    [] -> req_part
    _ -> {
      case required {
        [] -> "encode_opts(opts)"
        _ -> "list.append(" <> req_part <> ", encode_opts(opts))"
      }
    }
  }
}

// =============================================================================
// 10. GENERATORI DI TIPI
// =============================================================================

fn generate_scalar_to_json(name: String) -> String {
  "pub fn "
  <> to_snake_case(name)
  <> "_to_json(value: "
  <> name
  <> ") -> String {\n"
  <> "  value.value\n"
  <> "}"
}

fn generate_enum_type(name: String, values: List(String)) -> String {
  let variants =
    values
    |> list.map(fn(v) { enum_variant_to_gleam(name, v) })
    |> list.unique
    |> list.map(fn(v) { "  " <> v })
    |> string.join("\n")
  "pub type " <> name <> " {\n" <> variants <> "\n}"
}

fn enum_variant_to_gleam(enum_name: String, value: String) -> String {
  let converted =
    value
    |> string.split("_")
    |> list.map(fn(part) {
      case string.pop_grapheme(part) {
        Ok(#(first, rest)) -> string.uppercase(first) <> string.lowercase(rest)
        Error(_) -> part
      }
    })
    |> string.join("")
  enum_name <> converted
}

fn generate_enum_from_string(name: String, values: List(String)) -> String {
  let cases =
    values
    |> list.map(fn(v) {
      let variant = enum_variant_to_gleam(name, v)
      "    \"" <> variant <> "\" -> " <> variant
    })
    |> string.join("\n")
  "pub fn "
  <> to_snake_case(name)
  <> "_from_string(value: String) -> "
  <> name
  <> " {\n"
  <> "  case value {\n"
  <> cases
  <> "\n    _ -> panic\n"
  <> "  }\n"
  <> "}"
}

fn generate_enum_to_json(name: String, values: List(String)) -> String {
  let cases =
    values
    |> list.map(fn(v) { enum_variant_to_gleam(name, v) })
    |> list.unique
    |> list.map(fn(variant) { "    " <> variant <> " -> \"" <> variant <> "\"" })
    |> string.join("\n")
  "pub fn "
  <> to_snake_case(name)
  <> "_to_json(value: "
  <> name
  <> ") -> String {\n"
  <> "  case value {\n"
  <> cases
  <> "\n  }\n}"
}

fn generate_input_to_json(
  name: String,
  fields: List(types.InputField),
  type_defs: List(TypeDef),
) -> String {
  let field_strs =
    fields
    |> list.map(fn(f) {
      "    #(\""
      <> f.name
      <> "\", "
      <> type_ref_to_gql_value_local(
        "value." <> to_snake_case(f.name),
        f.type_,
        type_defs,
      )
      <> ")"
    })
    |> string.join(",\n")
  "pub fn "
  <> to_snake_case(name)
  <> "_to_json(value: "
  <> name
  <> ") -> List(#(String, types.Value)) {\n"
  <> "  [\n"
  <> field_strs
  <> "\n  ]\n}"
}

fn generate_object_option_type(
  all_opts: List(ArgDef),
  type_defs: List(TypeDef),
) -> String {
  case all_opts {
    [] -> ""
    _ -> {
      let variants =
        all_opts
        |> list.map(fn(arg: ArgDef) {
          let type_name = get_return_type_name(arg.type_)
          let input_type = case classify_type(type_name, type_defs) {
            IsScalar -> "String"
            _ -> print_type_ref(arg.type_, type_defs)
          }
          // USA IL NOME UNICO QUI
          "  " <> get_variant_name(arg, all_opts) <> "(" <> input_type <> ")"
        })
        |> string.join("\n")
      "pub type Opt {\n" <> variants <> "\n}\n\n"
    }
  }
}

fn generate_object_encode_opts(
  all_opts: List(ArgDef),
  type_defs: List(TypeDef),
) -> String {
  case all_opts {
    [] -> ""
    _ -> {
      let cases =
        all_opts
        |> list.map(fn(arg) {
          let variant = get_variant_name(arg, all_opts)
          // NOME UNICO
          let type_name = get_return_type_name(arg.type_)
          let gql_val = case classify_type(type_name, type_defs) {
            IsScalar -> "types.GString(val)"
            _ -> type_ref_to_gql_value("val", arg.type_, type_defs)
          }
          "    "
          <> variant
          <> "(val) -> Ok(#(\""
          <> arg.name
          <> "\", "
          <> gql_val
          <> "))"
        })
        |> string.join("\n")
      "pub fn encode_opts(opts: List(Opt)) -> List(#(String, types.Value)) {\n"
      <> "  list.filter_map(opts, fn(opt) {\n"
      <> "    case opt {\n"
      <> cases
      <> "\n      _ -> Error(Nil)\n"
      <> "    }\n"
      <> "  })\n"
      <> "}\n\n"
    }
  }
}

// Traslazione diretta della dag chain function nel modulo oggetto.
// Non riceve client — dati separati dall'esecuzione.
fn generate_constructor(
  name: String,
  query_field: FieldDef,
  type_defs: List(TypeDef),
) -> String {
  let #(required, optional) = split_args(query_field.arguments)
  let args_sig =
    join_sig([
      build_required_sig(required, type_defs),
      build_opts_sig(optional, "Opt"),
    ])
  let gql_args = case required, optional {
    [], [] -> "[]"
    [], _ -> "encode_opts(opts)"
    _, [] -> generate_gql_args(required, type_defs)
    _, _ ->
      "list.append("
      <> generate_gql_args(required, type_defs)
      <> ", encode_opts(opts))"
  }
  "pub fn "
  <> to_snake_case(name)
  <> "("
  <> args_sig
  <> ") -> t."
  <> name
  <> " {\n"
  <> "  let field = types.Field(name: \""
  <> query_field.name
  <> "\", args: "
  <> gql_args
  <> ", subfields: [])\n"
  <> "  t."
  <> name
  <> "(op: types.Pure([field]))\n"
  <> "}\n\n"
}

fn generate_types_module(type_defs: List(TypeDef)) -> String {
  let header = "// AUTO-GENERATED BY DAGGER_GLEAM - DO NOT EDIT\n\n"
  let imports = "import dagger/types.{type DaggerOp, type Field} as types\n\n"
  let types =
    list.filter_map(type_defs, fn(td) {
      case td {
        ObjectDef(name, _, _) ->
          Ok(
            "pub type "
            <> name
            <> " {\n  "
            <> name
            <> "(op: types.DaggerOp(List(types.Field)))\n}",
          )
        BoxDef(_, _) -> Error(Nil)
        EnumDef(name, _, values) ->
          Ok(
            generate_enum_type(name, values)
            <> "\n\n"
            <> generate_enum_to_json(name, values)
            <> "\n\n"
            <> generate_enum_from_string(name, values),
          )
        ScalarDef(name, _) ->
          Ok(
            "pub type "
            <> name
            <> " {\n  "
            <> name
            <> "(value: String)\n}"
            <> "\n\n"
            <> generate_scalar_to_json(name),
          )
        InputDef(name, _, fields) -> {
          let field_strs =
            fields
            |> list.map(fn(f) {
              "    "
              <> to_snake_case(f.name)
              <> ": "
              <> print_type_ref_local(f.type_, type_defs)
            })
            |> string.join(",\n")
          Ok(
            "pub type "
            <> name
            <> " {\n  "
            <> name
            <> "(\n"
            <> field_strs
            <> ",\n  )\n}"
            <> "\n\n"
            <> generate_input_to_json(name, fields, type_defs),
          )
        }
        AliasedDef(_, _) -> Error(Nil)
        IgnoredDef(_, _) -> Error(Nil)
      }
    })
    |> string.join("\n\n")
  header <> imports <> types
}

// =============================================================================
// 11. GENERATORI DI FUNZIONI - Moduli oggetto
// =============================================================================

fn generate_function(
  parent_name: String,
  field: FieldDef,
  type_defs: List(TypeDef),
) -> String {
  case is_list_of_object(field.return_type, type_defs) {
    True -> generate_selection_function(parent_name, field, type_defs)
    False ->
      case is_terminal(field.return_type, type_defs) {
        True -> generate_terminal_function(parent_name, field, type_defs)
        False -> generate_chain_function(parent_name, field, type_defs)
      }
  }
}

fn generate_chain_function(
  parent_name: String,
  field: FieldDef,
  type_defs: List(TypeDef),
) -> String {
  let return_type = print_type_ref(field.return_type, type_defs)
  let return_type_name =
    get_return_type_name(field.return_type)
    |> resolve_box(type_defs)
  let sig =
    join_sig([
      "parent: t." <> parent_name,
      generate_args_sig(field.arguments, type_defs),
    ])
  description_for(field)
  <> "pub fn "
  <> fn_name_for(field)
  <> "("
  <> sig
  <> ") -> "
  <> return_type
  <> " {\n"
  <> "  let field = types.Field(name: \""
  <> field.name
  <> "\", args: "
  <> generate_gql_args(field.arguments, type_defs)
  <> ", subfields: [])\n"
  <> "  let new_op = {\n"
  <> "    use q <- types.bind(parent.op)\n"
  <> "    types.Pure(list.append(q, [field]))\n"
  <> "  }\n"
  <> "  t."
  <> return_type_name
  <> "(op: new_op)\n"
  <> "}"
}

// Terminal: CPS — riceve client e handler, non restituisce Result direttamente.
fn generate_terminal_function(
  parent_name: String,
  field: FieldDef,
  type_defs: List(TypeDef),
) -> String {
  let return_type = terminal_return_type(field.return_type, type_defs)
  let sig =
    join_sig([
      "parent: t." <> parent_name,
      generate_args_sig(field.arguments, type_defs),
      build_client_sig(),
      "then handler: fn(Try(" <> return_type <> ")) -> a",
    ])
  let fetch_body =
    generate_fetch_body(field.name, "parent.op", field.return_type, type_defs)
  description_for(field)
  <> "pub fn "
  <> fn_name_for(field)
  <> "("
  <> sig
  <> ") -> a {\n"
  <> "  let field = types.Field(name: \""
  <> field.name
  <> "\", args: "
  <> generate_gql_args(field.arguments, type_defs)
  <> ", subfields: [])\n"
  <> fetch_body
  <> "  handler(interpreter.run(op, client))\n"
  <> "}"
}

// Selection: CPS con select + client + handler.
fn generate_selection_function(
  parent_name: String,
  field: FieldDef,
  type_defs: List(TypeDef),
) -> String {
  let return_type = print_type_ref(field.return_type, type_defs)
  let inner = inner_type(field.return_type)
  let inner_name = get_return_type_name(inner)
  let inner_ref = "t." <> inner_name
  let dummy = inner_ref <> "(op: types.Pure([]))"
  let inner_constructor = inner_ref <> "(op: types.Pure(full_query))"
  let sig =
    join_sig([
      "parent: t." <> parent_name,
      generate_args_sig(field.arguments, type_defs),
      "select select: fn(" <> inner_ref <> ") -> List(types.Field)",
      build_client_sig(),
      "then handler: fn(Try(" <> return_type <> ")) -> a",
    ])
  let fetch_body =
    generate_fetch_list_body(field.name, "parent.op", inner_constructor)
  description_for(field)
  <> "pub fn "
  <> fn_name_for(field)
  <> "("
  <> sig
  <> ") -> a {\n"
  <> "  let subfields = select("
  <> dummy
  <> ")\n"
  <> "  let field = types.Field(name: \""
  <> field.name
  <> "\", args: "
  <> generate_gql_args(field.arguments, type_defs)
  <> ", subfields: subfields)\n"
  <> fetch_body
  <> "  handler(interpreter.run(op, client))\n"
  <> "}"
}

fn generate_object_functions(
  name: String,
  fields: List(FieldDef),
  query_fields: List(FieldDef),
  type_defs: List(TypeDef),
) -> String {
  let all_opts =
    fields
    |> list.flat_map(fn(f) { f.arguments })
    |> list.filter(fn(arg) {
      case arg.type_ {
        NonNull(_) -> False
        _ -> True
      }
    })
    |> list.append(get_query_args_for_type(name, query_fields))
    |> unique_args()
  let header = "// AUTO-GENERATED BY DAGGER_GLEAM - DO NOT EDIT\n\n"
  let imports =
    "import dagger/types.{type Client, type Try} as types\n"
    <> "import dagger/interpreter\n"
    <> "import dagger/dsl/types as t\n"
    <> "import gleam/dynamic/decode\n"
    <> "import gleam/list\n\n"
  let options_type = generate_object_option_type(all_opts, type_defs)
  let encode_func = generate_object_encode_opts(all_opts, type_defs)
  let constructor = case get_query_field_for_type(name, query_fields) {
    option.Some(qf) -> generate_constructor(name, qf, type_defs)
    option.None -> ""
  }
  let constructor_name = to_snake_case(name)
  let functions =
    fields
    |> list.filter(fn(field) { fn_name_for(field) != constructor_name })
    |> list.map(fn(field) { generate_function(name, field, type_defs) })
    |> string.join("\n\n")
  header <> imports <> options_type <> encode_func <> constructor <> functions
}

// =============================================================================
// 12. GENERATORI DI FUNZIONI - Modulo dag
// dag espone solo terminal e selection — le chain sono nei moduli oggetto
// =============================================================================

fn generate_dag_function(field: FieldDef, type_defs: List(TypeDef)) -> String {
  case is_list_of_object(field.return_type, type_defs) {
    True -> generate_dag_selection_function(field, type_defs)
    False -> generate_dag_terminal_function(field, type_defs)
  }
}

// dag terminal: nessun parent — la query parte da types.Pure([])
fn generate_dag_terminal_function(
  field: FieldDef,
  type_defs: List(TypeDef),
) -> String {
  let #(required, optional) = split_args(field.arguments)
  let return_type = terminal_return_type(field.return_type, type_defs)
  let sig = build_cps_sig(required, optional, return_type, type_defs)
  let fetch_body =
    generate_fetch_body(
      field.name,
      "types.Pure([])",
      field.return_type,
      type_defs,
    )
  description_for(field)
  <> "pub fn "
  <> fn_name_for(field)
  <> "("
  <> sig
  <> ") -> a {\n"
  <> "  let field = types.Field(name: \""
  <> field.name
  <> "\", args: "
  <> generate_gql_args(field.arguments, type_defs)
  <> ", subfields: [])\n"
  <> fetch_body
  <> "  handler(interpreter.run(op, client))\n"
  <> "}"
}

// dag selection: CPS con select + client + handler
fn generate_dag_selection_function(
  field: FieldDef,
  type_defs: List(TypeDef),
) -> String {
  let #(required, optional) = split_args(field.arguments)
  let inner = inner_type(field.return_type)
  let inner_name = get_return_type_name(inner)
  let inner_ref = "t." <> inner_name
  let return_type = print_type_ref(field.return_type, type_defs)
  let dummy = inner_ref <> "(op: types.Pure([]))"
  let inner_constructor = inner_ref <> "(op: types.Pure(full_query))"
  let sig =
    join_sig([
      build_required_sig(required, type_defs),
      build_opts_sig(optional, "Opt"),
      "select select: fn(" <> inner_ref <> ") -> List(types.Field)",
      build_client_sig(),
      "then handler: fn(Try(" <> return_type <> ")) -> a",
    ])
  let fetch_body =
    generate_fetch_list_body(field.name, "types.Pure([])", inner_constructor)
  description_for(field)
  <> "pub fn "
  <> fn_name_for(field)
  <> "("
  <> sig
  <> ") -> a {\n"
  <> "  let subfields = select("
  <> dummy
  <> ")\n"
  <> "  let field = types.Field(name: \""
  <> field.name
  <> "\", args: "
  <> generate_gql_args(field.arguments, type_defs)
  <> ", subfields: subfields)\n"
  <> fetch_body
  <> "  handler(interpreter.run(op, client))\n"
  <> "}"
}

fn generate_dag_module(
  fields: List(FieldDef),
  type_defs: List(TypeDef),
) -> String {
  let header = "// AUTO-GENERATED BY DAGGER_GLEAM - DO NOT EDIT\n\n"
  let imports =
    "import dagger/types.{type Client, type Try} as types\n"
    <> "import dagger/interpreter\n"
    <> "import dagger/dsl/types as t\n"
    <> "import gleam/dynamic/decode\n"
    <> "import gleam/list\n\n"
  // dag espone solo primitive e liste — le chain sono nei moduli oggetto
  let functions =
    fields
    |> list.filter(fn(f) {
      is_terminal(f.return_type, type_defs)
      || is_list_of_object(f.return_type, type_defs)
    })
    |> list.map(fn(f) { generate_dag_function(f, type_defs) })
    |> string.join("\n\n")
  header <> imports <> functions
}

// =============================================================================
// 13. ENTRY POINT PUBBLICO
// =============================================================================

pub fn files_to_generate(
  type_defs: List(TypeDef),
  query_type_name: String,
) -> List(#(String, String)) {
  let types_file = #("types.gleam", generate_types_module(type_defs))
  let query_fields = get_query_fields(type_defs, query_type_name)
  let function_files =
    list.filter_map(type_defs, fn(td) {
      case td {
        ObjectDef(name, _, fields) if name == query_type_name ->
          Ok(#("dag.gleam", generate_dag_module(fields, type_defs)))
        ObjectDef(name, _, fields) ->
          Ok(#(
            to_snake_case(name) <> ".gleam",
            generate_object_functions(name, fields, query_fields, type_defs),
          ))
        _ -> Error(Nil)
      }
    })
  [types_file, ..function_files]
}

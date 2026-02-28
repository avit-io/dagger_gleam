// =============================================================================
// ENCODER - Risolve TypeDef/TypeRef e produce strutture Decl
// =============================================================================
// Contiene tutta la logica che richiede TypeDef/TypeRef:
//   - classificazione tipi
//   - stampa TypeRef come stringa Gleam
//   - serializzazione GQL
//   - decodifica
//   - costruzione firme
//   - generazione tipi (enum, scalar, input, types.gleam)
//   - raggruppamento moduli
//   - produzione di ModuleDecl da campi schema
// =============================================================================

import dagger/decl.{
  type FunctionDecl, type ModuleDecl, type OptDecl, Chain, Cps, FunctionDecl,
  ModuleDecl, OptDecl, Selection,
}
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
// TIPI
// =============================================================================

pub type TypeClass {
  IsScalar
  IsEnum
  IsObject
  IsInput
  IsBox
}

// =============================================================================
// CLASSIFICAZIONE
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

fn get_return_type_name(ref: TypeRef) -> String {
  case ref {
    Named(name) -> name
    NonNull(inner) -> get_return_type_name(inner)
    ListOf(inner) -> get_return_type_name(inner)
  }
}

fn inner_type(ref: TypeRef) -> TypeRef {
  case ref {
    ListOf(inner) -> inner
    NonNull(inner) -> inner_type(inner)
    other -> other
  }
}

fn resolve_box(name: String, type_defs: List(TypeDef)) -> String {
  list.find_map(type_defs, fn(td) {
    case td {
      BoxDef(n, inner) if n == name -> Ok(inner)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap(name)
}

// =============================================================================
// STAMPA TYPEREF
// =============================================================================

fn print_type_ref(ref: TypeRef, type_defs: List(TypeDef)) -> String {
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
        Ok(inner) -> "t." <> inner
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

fn terminal_return_type(ref: TypeRef, type_defs: List(TypeDef)) -> String {
  let name = get_return_type_name(ref)
  case classify_type(name, type_defs) {
    IsScalar -> "String"
    _ -> print_type_ref(ref, type_defs)
  }
}

// =============================================================================
// HELPER DI FIRMA
// =============================================================================

fn join_sig(parts: List(String)) -> String {
  parts
  |> list.filter(fn(p) { p != "" })
  |> string.join(", ")
}

fn build_client_sig() -> String {
  "client client: Client"
}

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
    escape_reserved(to_snake_case(arg.name))
    <> " "
    <> escape_reserved(to_snake_case(arg.name))
    <> ": "
    <> t
  })
  |> string.join(", ")
}

fn build_opts_sig(optional: List(ArgDef)) -> String {
  case optional {
    [] -> ""
    _ -> "with with_fn: fn(Opts) -> Opts"
  }
}

fn build_cps_sig(
  required: List(ArgDef),
  optional: List(ArgDef),
  return_type: String,
  type_defs: List(TypeDef),
) -> String {
  join_sig([
    build_required_sig(required, type_defs),
    build_opts_sig(optional),
    build_client_sig(),
    "then handler: fn(Try(" <> return_type <> ")) -> a",
  ])
}

fn generate_args_sig(args: List(ArgDef), type_defs: List(TypeDef)) -> String {
  let #(required, optional) = split_args(args)
  join_sig([
    build_required_sig(required, type_defs),
    build_opts_sig(optional),
  ])
}

// =============================================================================
// SERIALIZZAZIONE GQL
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
// GQL ARGS
// =============================================================================

fn generate_gql_args(args: List(ArgDef), type_defs: List(TypeDef)) -> String {
  let #(required, optional) = split_args(args)
  let req_fields =
    required
    |> list.map(fn(arg) {
      "#(\""
      <> arg.name
      <> "\", "
      <> type_ref_to_gql_value(
        escape_reserved(to_snake_case(arg.name)),
        arg.type_,
        type_defs,
      )
      <> ")"
    })
  case optional {
    [] -> "[" <> string.join(req_fields, ", ") <> "]"
    _ ->
      case required {
        [] -> "encode_opts(opts)"
        _ ->
          "list.append(["
          <> string.join(req_fields, ", ")
          <> "], encode_opts(opts))"
      }
  }
}

// =============================================================================
// ARGS HELPERS
// =============================================================================

fn split_args(args: List(ArgDef)) -> #(List(ArgDef), List(ArgDef)) {
  list.partition(args, fn(arg) {
    case arg.type_ {
      NonNull(_) -> True
      _ -> False
    }
  })
}

fn get_variant_name(arg: ArgDef, all_opts: List(ArgDef)) -> String {
  let ArgDef(name: argn, type_: argt, ..) = arg
  let same_name_different_type =
    list.any(all_opts, fn(a) {
      let ArgDef(name: an, type_: at, ..) = a
      an == argn && at != argt
    })
  case same_name_different_type {
    False -> capitalize(argn)
    True -> capitalize(argn) <> get_return_type_name(argt)
  }
}

fn resolve_opt_variants(all_opts: List(ArgDef)) -> List(#(String, ArgDef)) {
  list.map(all_opts, fn(arg) { #(get_variant_name(arg, all_opts), arg) })
}

// =============================================================================
// QUERY HELPERS
// =============================================================================

pub fn get_query_fields(
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

fn get_query_field_for_type(
  target_name: String,
  query_fields: List(FieldDef),
) -> option.Option(FieldDef) {
  list.find(query_fields, fn(f) {
    get_return_type_name(f.return_type) == target_name
  })
  |> option.from_result
}

// =============================================================================
// DECODIFICA
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

fn pure_ok_for_type(ref: TypeRef) -> String {
  let base = inner_type(ref)
  case base {
    Named("Nil") -> "types.Pure(Ok(Nil))"
    _ -> "types.Pure(Ok(val))"
  }
}

// =============================================================================
// FORMATTAZIONE (duplicata da printer per evitare import circolare)
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
// GENERATORI DI TIPI (types.gleam)
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
    |> list.unique
    |> list.map(fn(v) {
      let variant = enum_variant_to_gleam(name, v)
      "    \"" <> v <> "\" -> " <> variant
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
    list.fold(values, [], fn(acc, v) {
      let variant = enum_variant_to_gleam(name, v)

      // Usiamo il pattern matching direttamente nell'argomento della funzione
      let already_exists =
        list.any(acc, fn(pair) {
          let #(existing_variant, _) = pair
          existing_variant == variant
        })

      case already_exists {
        True -> acc
        False -> [#(variant, v), ..acc]
        // Aggiungiamo in testa (più veloce)
      }
    })
    |> list.reverse
    // Rimettiamo l'ordine originale
    |> list.map(fn(pair) {
      let #(variant, v) = pair
      "    " <> variant <> " -> \"" <> v <> "\""
    })
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
        "value." <> escape_reserved(to_snake_case(f.name)),
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

/// Genera il contenuto di types.gleam dal set di TypeDef.
pub fn types_module_content(type_defs: List(TypeDef)) -> String {
  let header = "// AUTO-GENERATED BY DAGGER_GLEAM - DO NOT EDIT\n\n"
  let imports = "import dagger/types as types\n\n"
  let types_content =
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
  header <> imports <> types_content
}

// =============================================================================
// COSTRUZIONE OptDecl
// =============================================================================

fn build_opt_decls(
  all_opts: List(ArgDef),
  type_defs: List(TypeDef),
) -> List(OptDecl) {
  resolve_opt_variants(all_opts)
  |> list.map(fn(pair) {
    let #(variant_name, arg) = pair
    let type_name = get_return_type_name(arg.type_)
    let gleam_type = case classify_type(type_name, type_defs) {
      IsScalar -> "String"
      _ -> print_type_ref(arg.type_, type_defs)
    }
    let gql_value = case classify_type(type_name, type_defs) {
      IsScalar -> "types.GString(val)"
      _ -> type_ref_to_gql_value("val", arg.type_, type_defs)
    }
    OptDecl(
      variant_name: variant_name,
      arg_name: arg.name,
      gleam_type: gleam_type,
      gql_value: gql_value,
      universal: False,
      tag: "",
    )
  })
}

// =============================================================================
// COSTRUZIONE FunctionDecl — oggetto (con parent)
// =============================================================================

fn field_to_function_decl(
  parent_name: String,
  field: FieldDef,
  type_defs: List(TypeDef),
) -> FunctionDecl {
  case is_list_of_object(field.return_type, type_defs) {
    True -> field_to_selection_decl(parent_name, field, type_defs, True)
    False ->
      case is_terminal(field.return_type, type_defs) {
        True -> field_to_cps_decl(parent_name, field, type_defs, True)
        False -> field_to_chain_decl(parent_name, field, type_defs, True)
      }
  }
}

fn field_to_chain_decl(
  parent_name: String,
  field: FieldDef,
  type_defs: List(TypeDef),
  is_object: Bool,
) -> FunctionDecl {
  let return_type = print_type_ref(field.return_type, type_defs)
  let return_type_name =
    get_return_type_name(field.return_type)
    |> resolve_box(type_defs)
  let gql_args = generate_gql_args(field.arguments, type_defs)
  let sig = case is_object {
    True ->
      join_sig([
        "parent: t." <> parent_name,
        generate_args_sig(field.arguments, type_defs),
      ])
    False -> generate_args_sig(field.arguments, type_defs)
  }
  let #(_, optional) = split_args(field.arguments)
  let relevant_opts =
    list.map(build_opt_decls(optional, type_defs), fn(o) { o.variant_name })
  FunctionDecl(
    name: fn_name_for(field),
    docs: description_for(field),
    signature: sig,
    return_type: return_type,
    body: Chain(
      gql_field: field.name,
      gql_args: gql_args,
      return_type_name: return_type_name,
      parent: is_object,
    ),
    relevant_opts: relevant_opts,
    opt_tag: "",
  )
}

fn field_to_cps_decl(
  parent_name: String,
  field: FieldDef,
  type_defs: List(TypeDef),
  is_object: Bool,
) -> FunctionDecl {
  let return_type = terminal_return_type(field.return_type, type_defs)
  let gql_args = generate_gql_args(field.arguments, type_defs)
  let decoder = decode_for_type(field.return_type, type_defs)
  let pure_ok = pure_ok_for_type(field.return_type)
  let #(required, optional) = split_args(field.arguments)
  let sig = case is_object {
    True -> {
      let args_part = generate_args_sig(field.arguments, type_defs)
      join_sig([
        "parent: t." <> parent_name,
        args_part,
        build_client_sig(),
        "then handler: fn(Try(" <> return_type <> ")) -> a",
      ])
    }
    False -> build_cps_sig(required, optional, return_type, type_defs)
  }
  let relevant_opts =
    list.map(build_opt_decls(optional, type_defs), fn(o) { o.variant_name })
  FunctionDecl(
    name: fn_name_for(field),
    docs: description_for(field),
    signature: sig,
    return_type: "a",
    body: Cps(
      gql_field: field.name,
      gql_args: gql_args,
      decoder: decoder,
      pure_ok: pure_ok,
      parent: is_object,
    ),
    relevant_opts: relevant_opts,
    opt_tag: "",
  )
}

fn field_to_selection_decl(
  parent_name: String,
  field: FieldDef,
  type_defs: List(TypeDef),
  is_object: Bool,
) -> FunctionDecl {
  let inner = inner_type(field.return_type)
  let inner_name = get_return_type_name(inner)
  let inner_ref = "t." <> inner_name
  let return_type = print_type_ref(field.return_type, type_defs)
  let gql_args = generate_gql_args(field.arguments, type_defs)
  let #(required, optional) = split_args(field.arguments)
  let sig = case is_object {
    True -> {
      let args_part = generate_args_sig(field.arguments, type_defs)
      join_sig([
        "parent: t." <> parent_name,
        args_part,
        "select select: fn(" <> inner_ref <> ") -> List(types.Field)",
        build_client_sig(),
        "then handler: fn(Try(" <> return_type <> ")) -> a",
      ])
    }
    False ->
      join_sig([
        build_required_sig(required, type_defs),
        build_opts_sig(optional),
        "select select: fn(" <> inner_ref <> ") -> List(types.Field)",
        build_client_sig(),
        "then handler: fn(Try(" <> return_type <> ")) -> a",
      ])
  }
  let relevant_opts =
    list.map(build_opt_decls(optional, type_defs), fn(o) { o.variant_name })
  FunctionDecl(
    name: fn_name_for(field),
    docs: description_for(field),
    signature: sig,
    return_type: "a",
    body: Selection(
      gql_field: field.name,
      gql_args: gql_args,
      inner_type: inner_name,
      parent: is_object,
    ),
    relevant_opts: relevant_opts,
    opt_tag: "",
  )
}

// =============================================================================
// COSTRUZIONE COSTRUTTORE (dag → oggetto, parent=False)
// =============================================================================

fn build_constructor_decl(
  name: String,
  query_field: FieldDef,
  type_defs: List(TypeDef),
) -> FunctionDecl {
  let #(required, optional) = split_args(query_field.arguments)
  let sig =
    join_sig([
      build_required_sig(required, type_defs),
      build_opts_sig(optional),
    ])
  let gql_args = generate_gql_args(query_field.arguments, type_defs)
  let relevant_opts =
    list.map(build_opt_decls(optional, type_defs), fn(o) { o.variant_name })
  FunctionDecl(
    name: to_snake_case(name),
    docs: "",
    signature: sig,
    return_type: "t." <> name,
    body: Chain(
      gql_field: query_field.name,
      gql_args: gql_args,
      return_type_name: name,
      parent: False,
    ),
    relevant_opts: relevant_opts,
    opt_tag: "",
  )
}

// =============================================================================
// API PUBBLICA: to_module_decl
// =============================================================================

/// Produce un ModuleDecl da un tipo oggetto o dal modulo dag.
/// Se name è un ObjectDef noto in type_defs → object mode (con parent).
/// Altrimenti → dag mode (senza parent).
pub fn to_module_decl(
  name: String,
  fields: List(FieldDef),
  query_fields: List(FieldDef),
  type_defs: List(TypeDef),
  _fn_prefix: String,
) -> ModuleDecl {
  let is_object =
    list.any(type_defs, fn(td) {
      case td {
        ObjectDef(n, _, _) if n == name -> True
        _ -> False
      }
    })

  let constructor_name = to_snake_case(name)

  let constructor_fn = case is_object {
    True ->
      case get_query_field_for_type(name, query_fields) {
        option.Some(qf) ->
          option.Some(build_constructor_decl(name, qf, type_defs))
        option.None -> option.None
      }
    False -> option.None
  }

  let method_fields = case is_object {
    True -> list.filter(fields, fn(f) { fn_name_for(f) != constructor_name })
    False -> fields
  }

  let method_fns = case is_object {
    True ->
      list.map(method_fields, fn(f) {
        field_to_function_decl(name, f, type_defs)
      })
    False ->
      list.map(method_fields, fn(f) {
        case is_list_of_object(f.return_type, type_defs) {
          True -> field_to_selection_decl(name, f, type_defs, False)
          False ->
            case is_terminal(f.return_type, type_defs) {
              True -> field_to_cps_decl(name, f, type_defs, False)
              False -> field_to_chain_decl(name, f, type_defs, False)
            }
        }
      })
  }

  let all_functions = case constructor_fn {
    option.Some(c) -> [c, ..method_fns]
    option.None -> method_fns
  }

  // Aggrega tutti gli opt opzionali da tutti i campi del modulo, deduplicando
  let collect_field_opts = fn(f: FieldDef) {
    let #(_, optional) = split_args(f.arguments)
    build_opt_decls(optional, type_defs)
  }
  let constructor_field_opts = case is_object {
    False -> []
    True ->
      case get_query_field_for_type(name, query_fields) {
        option.Some(qf) -> collect_field_opts(qf)
        option.None -> []
      }
  }
  let method_field_opts = list.flat_map(method_fields, collect_field_opts)
  let module_opts =
    list.append(constructor_field_opts, method_field_opts)
    |> list.fold([], fn(acc, opt) {
      case list.any(acc, fn(o: OptDecl) { o.variant_name == opt.variant_name }) {
        True -> acc
        False -> list.append(acc, [opt])
      }
    })

  // Bridge test: calcola opt universali e gruppi phantom
  let fn_opts_input =
    list.filter_map(all_functions, fn(f) {
      case f.relevant_opts {
        [] -> Error(Nil)
        opts -> Ok(#(f.name, opts))
      }
    })
  let #(universal_opts, groups) = compute_phantom_groups(fn_opts_input)
  let #(fn_to_tag, phantom_decls) =
    build_phantom_info(groups, fn_opts_input, universal_opts)

  // Aggiorna opt_tag e signature (sostituisce "fn(Opts) -> Opts" con il tag corretto)
  let tagged_functions =
    list.map(all_functions, fn(f) {
      let tag =
        list.find_map(fn_to_tag, fn(pair) {
          case pair.0 == f.name {
            True -> Ok(pair.1)
            False -> Error(Nil)
          }
        })
        |> result.unwrap("")
      let new_sig =
        string.replace(
          f.signature,
          "fn(Opts) -> Opts",
          "fn(Opts(" <> tag <> ")) -> Opts(" <> tag <> ")",
        )
      FunctionDecl(..f, opt_tag: tag, signature: new_sig)
    })

  // Aggiorna universal e tag su ogni opt
  // Per gli opt non-universali, il tag si ricava dalla prima funzione che lo usa
  let tagged_opts =
    list.map(module_opts, fn(o) {
      let is_universal = list.contains(universal_opts, o.variant_name)
      let opt_tag = case is_universal {
        True -> "a"
        False ->
          list.find_map(tagged_functions, fn(f) {
            case list.contains(f.relevant_opts, o.variant_name) {
              True -> Ok(f.opt_tag)
              False -> Error(Nil)
            }
          })
          |> result.unwrap("a")
      }
      OptDecl(..o, universal: is_universal, tag: opt_tag)
    })

  ModuleDecl(
    name: name,
    opts: tagged_opts,
    functions: tagged_functions,
    phantom_decls: phantom_decls,
  )
}

// =============================================================================
// PHANTOM GROUPS — Bridge Test
// =============================================================================

fn to_pascal_case(name: String) -> String {
  name
  |> string.split("_")
  |> list.map(capitalize)
  |> string.join("")
}

// Dato: fn_opts = [(fn_name, [variant_name])]
// Restituisce: (universal_variant_names, groups_of_fn_names)
fn compute_phantom_groups(
  fn_opts: List(#(String, List(String))),
) -> #(List(String), List(List(String))) {
  let all_variants =
    list.flat_map(fn_opts, fn(p) { p.1 })
    |> list.unique
  let base_count = list.length(connected_components(fn_opts, all_variants))
  let bridge_opts =
    list.filter(all_variants, fn(v) {
      let without = list.filter(all_variants, fn(w) { w != v })
      list.length(connected_components(fn_opts, without)) > base_count
    })
  let non_bridge =
    list.filter(all_variants, fn(v) { !list.contains(bridge_opts, v) })
  #(bridge_opts, connected_components(fn_opts, non_bridge))
}

fn connected_components(
  fn_opts: List(#(String, List(String))),
  active: List(String),
) -> List(List(String)) {
  find_components(list.map(fn_opts, fn(p) { p.0 }), fn_opts, active, [])
}

fn find_components(
  remaining: List(String),
  fn_opts: List(#(String, List(String))),
  active: List(String),
  acc: List(List(String)),
) -> List(List(String)) {
  case remaining {
    [] -> acc
    [first, ..rest] -> {
      let comp = bfs_component([first], [first], fn_opts, active)
      let new_remaining = list.filter(rest, fn(n) { !list.contains(comp, n) })
      find_components(new_remaining, fn_opts, active, [comp, ..acc])
    }
  }
}

fn bfs_component(
  queue: List(String),
  visited: List(String),
  fn_opts: List(#(String, List(String))),
  active: List(String),
) -> List(String) {
  case queue {
    [] -> visited
    [current, ..rest] -> {
      let curr_vars =
        list.find_map(fn_opts, fn(p) {
          case p.0 == current {
            True -> Ok(list.filter(p.1, fn(v) { list.contains(active, v) }))
            False -> Error(Nil)
          }
        })
        |> result.unwrap([])
      let new_neighbors =
        list.filter_map(fn_opts, fn(p) {
          let #(fname, fvars) = p
          case
            !list.contains(visited, fname)
            && list.any(curr_vars, fn(v) { list.contains(fvars, v) })
          {
            True -> Ok(fname)
            False -> Error(Nil)
          }
        })
      bfs_component(
        list.append(rest, new_neighbors),
        list.append(visited, new_neighbors),
        fn_opts,
        active,
      )
    }
  }
}

// Dato: groups (componenti connesse), fn_opts, universal_opts
// Restituisce: (fn_name → tag_name, phantom_decls)
fn build_phantom_info(
  groups: List(List(String)),
  fn_opts: List(#(String, List(String))),
  universal_opts: List(String),
) -> #(List(#(String, String)), List(#(String, List(String)))) {
  list.fold(groups, #([], []), fn(acc, group) {
    let #(fn_to_tag, tag_decls) = acc
    case group {
      [] -> acc
      [single] -> {
        let fn_vars =
          list.find_map(fn_opts, fn(p) {
            case p.0 == single {
              True -> Ok(p.1)
              False -> Error(Nil)
            }
          })
          |> result.unwrap([])
        let has_specific =
          list.any(fn_vars, fn(v) { !list.contains(universal_opts, v) })
        case has_specific {
          False ->
            #(list.append(fn_to_tag, [#(single, "a")]), tag_decls)
          True -> {
            let tag_name = "For" <> to_pascal_case(single)
            #(
              list.append(fn_to_tag, [#(single, tag_name)]),
              list.append(tag_decls, [#(tag_name, [])]),
            )
          }
        }
      }
      multiple -> {
        let sorted = list.sort(multiple, string.compare)
        let first = result.unwrap(list.first(sorted), "")
        let type_name = to_pascal_case(first) <> "Fns"
        let variants = list.map(sorted, to_pascal_case)
        #(
          list.append(fn_to_tag, list.map(multiple, fn(n) { #(n, type_name) })),
          list.append(tag_decls, [#(type_name, variants)]),
        )
      }
    }
  })
}

// =============================================================================
// RAGGRUPPAMENTO
// =============================================================================

pub fn forced_groups() -> List(#(String, List(String))) {
  [
    #("git", ["GitRepository", "GitRef"]),
    #("engine", ["Engine", "EngineCache", "EngineCacheEntrySet"]),
  ]
}

pub fn build_type_groups(
  type_defs: List(TypeDef),
  query_type_name: String,
) -> List(#(String, List(String))) {
  let edges =
    list.filter_map(type_defs, fn(td) {
      case td {
        ObjectDef(name, _, fields) if name != query_type_name -> {
          let referenced =
            fields
            |> list.map(fn(f) { get_return_type_name(f.return_type) })
            |> list.filter(fn(n) {
              list.any(type_defs, fn(td2) {
                case td2 {
                  ObjectDef(n2, _, _) if n2 == n && n2 != query_type_name ->
                    True
                  _ -> False
                }
              })
            })
          Ok(#(name, referenced))
        }
        _ -> Error(Nil)
      }
    })
  let all_names = list.map(edges, fn(e) { e.0 })
  let referenced_by_others = list.flat_map(edges, fn(e) { e.1 })
  let roots =
    list.filter(all_names, fn(n) { !list.contains(referenced_by_others, n) })
  list.map(roots, fn(root) {
    #(to_snake_case(root), collect_group(root, edges, [root]))
  })
}

pub fn collect_group(
  name: String,
  edges: List(#(String, List(String))),
  visited: List(String),
) -> List(String) {
  let children =
    list.find_map(edges, fn(e) {
      case e.0 == name {
        True -> Ok(e.1)
        False -> Error(Nil)
      }
    })
    |> result.unwrap([])
    |> list.filter(fn(n) { !list.contains(visited, n) })
    |> list.filter(fn(child) {
      let refs =
        list.filter(edges, fn(e) { list.contains(e.1, child) && e.0 != child })
      list.length(refs) == 1
    })
  list.fold(children, visited, fn(acc, child) {
    collect_group(child, edges, list.append(acc, [child]))
  })
}

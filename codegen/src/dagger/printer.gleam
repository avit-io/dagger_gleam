// =============================================================================
// PRINTER - Genera codice Gleam da strutture Decl già risolte
// =============================================================================
// Struttura:
//   1. Import
//   2. Helper di formattazione (to_snake_case, capitalize, escape_reserved, ...)
//   3. Rendering Opt type e encode_opts
//   4. Rendering corpi funzione (render_chain_body, render_cps_body, render_selection_body)
//   5. Rendering funzioni (render_function)
//   6. Rendering modulo (render_module)
//   7. Grouped module (unico punto che tocca TypeDef, delega a encoder)
//   8. Entry point pubblico (files_to_generate)
// =============================================================================
//
// REGOLA: solo files_to_generate e generate_grouped_module toccano TypeDef.
//         Tutte le funzioni render_* operano solo su dagger/decl.{...}.
// =============================================================================

import dagger/decl.{
  type BodyKind, type FunctionDecl, type ModuleDecl, type OptDecl, Chain, Cps,
  Selection,
}
import dagger/encoder
import dagger/types.{type FieldDef, type TypeDef}
import gleam/list
import gleam/string

// =============================================================================
// 2. HELPER DI FORMATTAZIONE
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

fn fn_prefix_for(type_name: String, module_name: String) -> String {
  let capitalized_module = capitalize(module_name)
  let residual = case string.starts_with(type_name, capitalized_module) {
    True -> string.drop_start(type_name, string.length(capitalized_module))
    False -> type_name
  }
  case residual {
    "" -> to_snake_case(type_name) <> "_"
    _ -> to_snake_case(residual) <> "_"
  }
}

// =============================================================================
// 3. RENDERING OPT TYPE E ENCODE_OPTS
// =============================================================================

fn render_opts_record(opts: List(OptDecl)) -> String {
  case opts {
    [] -> ""
    _ -> {
      let fields =
        opts
        |> list.map(fn(o) {
          "    " <> to_snake_case(o.variant_name) <> ": Option(" <> o.gleam_type <> ")"
        })
        |> string.join(",\n")
      "pub type Opts {\n  Opts(\n" <> fields <> ",\n  )\n}\n\n"
    }
  }
}

fn render_defaults(opts: List(OptDecl)) -> String {
  case opts {
    [] -> ""
    _ -> {
      let fields =
        opts
        |> list.map(fn(o) { "    " <> to_snake_case(o.variant_name) <> ": None" })
        |> string.join(",\n")
      "fn defaults() -> Opts {\n  Opts(\n" <> fields <> ",\n  )\n}\n\n"
    }
  }
}

fn render_none(opts: List(OptDecl)) -> String {
  case opts {
    [] -> ""
    _ -> "pub fn none(opts: Opts) -> Opts {\n  opts\n}\n\n"
  }
}

fn render_setters(opts: List(OptDecl), fn_names: List(String)) -> String {
  case opts {
    [] -> ""
    _ ->
      opts
      |> list.map(fn(o) {
        let field = to_snake_case(o.variant_name)
        let fname = case list.contains(fn_names, field) {
          True -> "opt_" <> field
          False -> field
        }
        let constructor = case list.length(opts) {
          1 -> "Opts(" <> field <> ": Some(val))"
          _ -> "Opts(..opts, " <> field <> ": Some(val))"
        }
        "pub fn "
        <> fname
        <> "(opts: Opts, val: "
        <> o.gleam_type
        <> ") -> Opts {\n"
        <> "  "
        <> constructor
        <> "\n"
        <> "}"
      })
      |> string.join("\n\n")
      |> fn(s) { s <> "\n\n" }
  }
}

fn render_function_encoder(
  fn_full_name: String,
  relevant_variants: List(String),
  all_opts: List(OptDecl),
) -> String {
  case relevant_variants {
    [] -> ""
    _ -> {
      let relevant =
        list.filter(all_opts, fn(o: OptDecl) {
          list.contains(relevant_variants, o.variant_name)
        })
      let cases =
        relevant
        |> list.map(fn(o) {
          let fname = to_snake_case(o.variant_name)
          "    case opts."
          <> fname
          <> " {\n"
          <> "      Some(val) -> Ok(#(\""
          <> o.arg_name
          <> "\", "
          <> o.gql_value
          <> "))\n"
          <> "      None -> Error(Nil)\n"
          <> "    }"
        })
        |> string.join(",\n")
      "fn encode_"
      <> fn_full_name
      <> "(opts: Opts) -> List(#(String, types.Value)) {\n"
      <> "  list.filter_map([\n"
      <> cases
      <> "\n  ], fn(x) { x })\n"
      <> "}\n\n"
    }
  }
}

fn patch_body_encode_fn(body: BodyKind, encode_fn_name: String) -> BodyKind {
  let patch = fn(s: String) {
    string.replace(s, "encode_opts(opts)", encode_fn_name <> "(opts)")
  }
  case body {
    Chain(f, a, r, p) -> Chain(f, patch(a), r, p)
    Cps(f, a, d, ok, p) -> Cps(f, patch(a), d, ok, p)
    Selection(f, a, it, p) -> Selection(f, patch(a), it, p)
  }
}

// =============================================================================
// 4. RENDERING CORPI FUNZIONE
// =============================================================================

fn render_chain_body(body: BodyKind) -> String {
  case body {
    Chain(gql_field, gql_args, return_type_name, parent) -> {
      let field_line =
        "  let field = types.Field(name: \""
        <> gql_field
        <> "\", args: "
        <> gql_args
        <> ", subfields: [])\n"
      case parent {
        True ->
          field_line
          <> "  let new_op = {\n"
          <> "    use q <- types.bind(parent.op)\n"
          <> "    types.Pure(list.append(q, [field]))\n"
          <> "  }\n"
          <> "  t."
          <> return_type_name
          <> "(op: new_op)\n"
        False ->
          field_line
          <> "  t."
          <> return_type_name
          <> "(op: types.Pure([field]))\n"
      }
    }
    _ -> ""
  }
}

fn render_cps_body(body: BodyKind) -> String {
  case body {
    Cps(gql_field, gql_args, decoder, pure_ok, parent) -> {
      let query_expr = case parent {
        True -> "parent.op"
        False -> "types.Pure([])"
      }
      "  let field = types.Field(name: \""
      <> gql_field
      <> "\", args: "
      <> gql_args
      <> ", subfields: [])\n"
      <> "  let op = {\n"
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
      <> {
        let val_pat = case string.contains(pure_ok, "val") {
          True -> "val"
          False -> "_"
        }
        "          Ok(" <> val_pat <> ") -> " <> pure_ok <> "\n"
      }
      <> "          Error(_) -> types.Pure(Error(types.DecodingError(\""
      <> gql_field
      <> "\")))\n"
      <> "        }\n"
      <> "      }\n"
      <> "    )\n"
      <> "  }\n"
      <> "  handler(interpreter.run(op, client))\n"
    }
    _ -> ""
  }
}

fn render_selection_body(body: BodyKind) -> String {
  case body {
    Selection(gql_field, gql_args, inner_type_name, parent) -> {
      let inner_ref = "t." <> inner_type_name
      let dummy = inner_ref <> "(op: types.Pure([]))"
      let inner_constructor = inner_ref <> "(op: types.Pure(full_query))"
      let query_expr = case parent {
        True -> "parent.op"
        False -> "types.Pure([])"
      }
      "  let subfields = select("
      <> dummy
      <> ")\n"
      <> "  let field = types.Field(name: \""
      <> gql_field
      <> "\", args: "
      <> gql_args
      <> ", subfields: subfields)\n"
      <> "  let op = {\n"
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
      <> "          Ok(items) -> types.Pure(Ok(list.map(items, fn(_) { "
      <> inner_constructor
      <> " })))\n"
      <> "          Error(_) -> types.Pure(Error(types.DecodingError(\""
      <> gql_field
      <> "\")))\n"
      <> "        }\n"
      <> "      }\n"
      <> "    )\n"
      <> "  }\n"
      <> "  handler(interpreter.run(op, client))\n"
    }
    _ -> ""
  }
}

// =============================================================================
// 5. RENDERING FUNZIONI
// =============================================================================

fn render_function(
  decl: FunctionDecl,
  prefix: String,
  all_opts: List(OptDecl),
) -> String {
  let fn_full_name = prefix <> decl.name
  let patched_body = case decl.relevant_opts {
    [] -> decl.body
    _ -> patch_body_encode_fn(decl.body, "encode_" <> fn_full_name)
  }
  let opts_prelude = case decl.relevant_opts {
    [] -> ""
    _ -> "  let opts = with_fn(defaults())\n"
  }
  let body =
    opts_prelude
    <> case patched_body {
      Chain(_, _, _, _) -> render_chain_body(patched_body)
      Cps(_, _, _, _, _) -> render_cps_body(patched_body)
      Selection(_, _, _, _) -> render_selection_body(patched_body)
    }
  render_function_encoder(fn_full_name, decl.relevant_opts, all_opts)
  <> decl.docs
  <> "pub fn "
  <> fn_full_name
  <> "("
  <> decl.signature
  <> ") -> "
  <> decl.return_type
  <> " {\n"
  <> body
  <> "}"
}

// =============================================================================
// 6. RENDERING MODULO
// =============================================================================

fn has_terminal(decl: ModuleDecl) -> Bool {
  list.any(decl.functions, fn(f) {
    case f.body {
      Cps(..) | Selection(..) -> True
      _ -> False
    }
  })
}

fn module_imports(terminal: Bool, has_opts: Bool) -> String {
  let option_import = case has_opts {
    True -> "import gleam/option.{type Option, None, Some}\n"
    False -> ""
  }
  case terminal {
    True ->
      "import dagger/types.{type Client, type Try} as types\n"
      <> "import dagger/interpreter\n"
      <> "import dagger/dsl/types as t\n"
      <> "import gleam/dynamic/decode\n"
      <> "import gleam/list\n"
      <> option_import
      <> "\n"
    False ->
      "import dagger/types as types\n"
      <> "import dagger/dsl/types as t\n"
      <> "import gleam/list\n"
      <> option_import
      <> "\n"
  }
}

fn render_module(decl: ModuleDecl) -> String {
  let header = "// AUTO-GENERATED BY DAGGER_GLEAM - DO NOT EDIT\n\n"
  let imports = module_imports(has_terminal(decl), decl.opts != [])
  let fn_names = list.map(decl.functions, fn(f) { f.name })
  let opt_section =
    render_opts_record(decl.opts)
    <> render_defaults(decl.opts)
    <> render_none(decl.opts)
    <> render_setters(decl.opts, fn_names)
  let functions =
    decl.functions
    |> list.map(fn(f) { render_function(f, "", decl.opts) })
    |> string.join("\n\n")
  header <> imports <> opt_section <> functions
}

// =============================================================================
// 7. GROUPED MODULE
// Unico punto (oltre a files_to_generate) che tocca TypeDef — delega a encoder.
// =============================================================================

fn generate_grouped_module(
  group: List(#(String, String, List(FieldDef))),
  query_fields: List(FieldDef),
  type_defs: List(TypeDef),
) -> String {
  let header = "// AUTO-GENERATED BY DAGGER_GLEAM - DO NOT EDIT\n\n"

  let module_name = case group {
    [#(mn, _, _), ..] -> mn
    [] -> ""
  }

  // Costruisce (type_name, ModuleDecl) per ogni tipo del gruppo
  let type_data =
    list.map(group, fn(t) {
      let #(_, type_name, fields) = t
      let m =
        encoder.to_module_decl(type_name, fields, query_fields, type_defs, "")
      #(type_name, m)
    })

  let terminal =
    list.any(type_data, fn(td) {
      let #(_, m) = td
      list.any(m.functions, fn(f) {
        case f.body {
          Cps(..) | Selection(..) -> True
          _ -> False
        }
      })
    })
  // Merge opts da tutti i tipi del gruppo, deduplicando per variant_name
  let merged_opts =
    list.flat_map(type_data, fn(td) {
      let #(_, m) = td
      m.opts
    })
    |> list.fold([], fn(acc, opt) {
      case list.any(acc, fn(o: OptDecl) { o.variant_name == opt.variant_name }) {
        True -> acc
        False -> list.append(acc, [opt])
      }
    })
  let imports = module_imports(terminal, merged_opts != [])
  let all_fn_names =
    list.flat_map(type_data, fn(td) {
      let #(_, m) = td
      list.map(m.functions, fn(f) { f.name })
    })
  let opt_section =
    render_opts_record(merged_opts)
    <> render_defaults(merged_opts)
    <> render_none(merged_opts)
    <> render_setters(merged_opts, all_fn_names)

  // Trova nomi di funzione duplicati (esclusi i costruttori con parent=False)
  let all_fn_names =
    list.flat_map(type_data, fn(td) {
      let #(_, m) = td
      list.filter_map(m.functions, fn(f) {
        case f.body {
          Chain(_, _, _, False) -> Error(Nil)
          _ -> Ok(f.name)
        }
      })
    })
  let duplicate_names =
    list.filter(list.unique(all_fn_names), fn(n) {
      list.length(list.filter(all_fn_names, fn(m) { m == n })) > 1
    })

  // Render funzioni per ogni tipo
  let bodies =
    list.map(type_data, fn(td) {
      let #(type_name, m) = td
      let prefix = fn_prefix_for(type_name, module_name)
      list.map(m.functions, fn(f) {
        let actual_prefix = case f.body {
          Chain(_, _, _, False) -> ""
          // costruttore: mai prefissato
          _ ->
            case list.contains(duplicate_names, f.name) {
              True -> prefix
              False -> ""
            }
        }
        render_function(f, actual_prefix, merged_opts)
      })
      |> string.join("\n\n")
    })
    |> list.filter(fn(s) { s != "" })
    |> string.join("\n\n")

  header <> imports <> opt_section <> bodies
}

// =============================================================================
// 8. ENTRY POINT PUBBLICO
// =============================================================================

pub fn files_to_generate(
  type_defs: List(TypeDef),
  query_type_name: String,
) -> List(#(String, String)) {
  // 1. types.gleam
  let types_file = #("types.gleam", encoder.types_module_content(type_defs))

  // 2. dag.gleam
  let query_fields = encoder.get_query_fields(type_defs, query_type_name)
  let dag_file = case
    list.find_map(type_defs, fn(td) {
      case td {
        types.ObjectDef(name, _, fields) if name == query_type_name ->
          Ok(fields)
        _ -> Error(Nil)
      }
    })
  {
    Ok(dag_fields) ->
      [
        #(
          "dag.gleam",
          encoder.to_module_decl(
            "dag",
            dag_fields,
            query_fields,
            type_defs,
            "",
          )
            |> render_module,
        ),
      ]
    Error(_) -> []
  }

  // 3. Raccogli tutti gli ObjectDef non-query
  let object_defs =
    list.filter_map(type_defs, fn(td) {
      case td {
        types.ObjectDef(name, _, fields) if name != query_type_name ->
          Ok(#(name, fields))
        _ -> Error(Nil)
      }
    })

  // 4. Gruppi forzati
  let forced = encoder.forced_groups()
  let forced_names = list.flat_map(forced, fn(g) { g.1 })

  // 5. Auto-gruppi (escludendo i tipi già nei gruppi forzati)
  let remaining_type_defs =
    list.filter(type_defs, fn(td) {
      case td {
        types.ObjectDef(name, _, _) -> !list.contains(forced_names, name)
        _ -> True
      }
    })
  let auto_groups =
    encoder.build_type_groups(remaining_type_defs, query_type_name)
  let auto_grouped_names = list.flat_map(auto_groups, fn(g) { g.1 })
  let all_groups = list.append(forced, auto_groups)
  let all_grouped_names = list.append(forced_names, auto_grouped_names)

  // 6. File per gruppi
  let grouped_files =
    list.map(all_groups, fn(group) {
      let #(module_name, members) = group
      let group_defs =
        list.filter_map(members, fn(member) {
          list.find_map(object_defs, fn(od) {
            case od.0 == member {
              True -> Ok(#(module_name, od.0, od.1))
              False -> Error(Nil)
            }
          })
        })
      #(
        module_name <> ".gleam",
        generate_grouped_module(group_defs, query_fields, type_defs),
      )
    })

  // 7. File per tipi non raggruppati
  let ungrouped_files =
    list.filter_map(object_defs, fn(od) {
      case list.contains(all_grouped_names, od.0) {
        True -> Error(Nil)
        False ->
          Ok(#(
            to_snake_case(od.0) <> ".gleam",
            encoder.to_module_decl(od.0, od.1, query_fields, type_defs, "")
              |> render_module,
          ))
      }
    })

  [
    types_file,
    ..list.append(dag_file, list.append(grouped_files, ungrouped_files))
  ]
}

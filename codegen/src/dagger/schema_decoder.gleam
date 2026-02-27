import dagger/types.{
  type ArgDef, type FieldDef, type InputField, type TypeDef, type TypeRef,
  ArgDef, BoxDef, EnumDef, FieldDef, IgnoredDef, InputDef, InputField, ListOf,
  Named, NonNull, ObjectDef, ScalarDef,
}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

fn map_scalar_name(name: String) -> String {
  case name {
    "String" -> "String"
    "Int" -> "Int"
    "Float" -> "Float"
    "Boolean" -> "Bool"
    "Void" -> "Nil"
    "JSON" -> "String"
    other -> other
  }
}

fn is_builtin(name: String) -> Bool {
  case name {
    "Boolean" | "String" | "Int" | "Float" | "ID" | "Void" -> True
    _ -> False
  }
}

fn is_user_type(name: String) -> Bool {
  !string.starts_with(name, "__") && !string.starts_with(name, "_")
}

pub fn decode_type_ref(
  dyn: decode.Dynamic,
) -> Result(TypeRef, List(decode.DecodeError)) {
  use kind <- result.try(decode.run(dyn, decode.at(["kind"], decode.string)))
  case kind {
    "NON_NULL" -> {
      use inner_dyn <- result.try(decode.run(
        dyn,
        decode.at(["ofType"], decode.dynamic),
      ))
      use inner <- result.try(decode_type_ref(inner_dyn))
      Ok(NonNull(inner))
    }
    "LIST" -> {
      use inner_dyn <- result.try(decode.run(
        dyn,
        decode.at(["ofType"], decode.dynamic),
      ))
      use inner <- result.try(decode_type_ref(inner_dyn))
      Ok(ListOf(inner))
    }
    _ -> {
      use name <- result.try(decode.run(dyn, decode.at(["name"], decode.string)))
      Ok(Named(map_scalar_name(name)))
    }
  }
}

fn decode_input_field(
  dyn: decode.Dynamic,
) -> Result(InputField, List(decode.DecodeError)) {
  use name <- result.try(decode.run(dyn, decode.at(["name"], decode.string)))
  use desc <- result.try(decode.run(
    dyn,
    decode.at(["description"], decode.optional(decode.string)),
  ))
  use type_dyn <- result.try(decode.run(
    dyn,
    decode.at(["type"], decode.dynamic),
  ))
  use type_ <- result.try(decode_type_ref(type_dyn))
  Ok(InputField(name: name, description: desc, type_: type_))
}

fn decode_arg(dyn: decode.Dynamic) -> Result(ArgDef, List(decode.DecodeError)) {
  use name <- result.try(decode.run(dyn, decode.at(["name"], decode.string)))
  use desc <- result.try(decode.run(
    dyn,
    decode.at(["description"], decode.optional(decode.string)),
  ))
  use type_dyn <- result.try(decode.run(
    dyn,
    decode.at(["type"], decode.dynamic),
  ))
  use type_ <- result.try(decode_type_ref(type_dyn))
  Ok(ArgDef(name: name, description: desc, type_: type_))
}

fn decode_field(
  dyn: decode.Dynamic,
) -> Result(FieldDef, List(decode.DecodeError)) {
  use name <- result.try(decode.run(dyn, decode.at(["name"], decode.string)))
  use desc <- result.try(decode.run(
    dyn,
    decode.at(["description"], decode.optional(decode.string)),
  ))
  use args_dyn <- result.try(decode.run(
    dyn,
    decode.at(["args"], decode.list(decode.dynamic)),
  ))
  use args <- result.try(result.all(list.map(args_dyn, decode_arg)))
  use type_dyn <- result.try(decode.run(
    dyn,
    decode.at(["type"], decode.dynamic),
  ))
  use return_type <- result.try(decode_type_ref(type_dyn))
  Ok(FieldDef(
    name: name,
    description: desc,
    arguments: args,
    return_type: return_type,
  ))
}

fn decode_type_def(
  dyn: decode.Dynamic,
) -> Result(TypeDef, List(decode.DecodeError)) {
  use kind <- result.try(decode.run(dyn, decode.at(["kind"], decode.string)))
  use name <- result.try(decode.run(dyn, decode.at(["name"], decode.string)))
  use desc <- result.try(decode.run(
    dyn,
    decode.at(["description"], decode.optional(decode.string)),
  ))
  case kind {
    "OBJECT" ->
      case is_user_type(name) {
        False -> Ok(IgnoredDef(kind: kind, name: name))
        True -> {
          use fields_dyn <- result.try(decode.run(
            dyn,
            decode.at(["fields"], decode.list(decode.dynamic)),
          ))
          use fields <- result.try(
            result.all(list.map(fields_dyn, decode_field)),
          )
          Ok(ObjectDef(name: name, description: desc, fields: fields))
        }
      }
    "ENUM" ->
      case is_user_type(name) && !is_builtin(name) {
        False -> Ok(IgnoredDef(kind: kind, name: name))
        True -> {
          use values_dyn <- result.try(decode.run(
            dyn,
            decode.at(["enumValues"], decode.list(decode.dynamic)),
          ))
          use values <- result.try(
            result.all(
              list.map(values_dyn, fn(v) {
                decode.run(v, decode.at(["name"], decode.string))
              }),
            ),
          )
          Ok(EnumDef(name: name, description: desc, values: values))
        }
      }
    "SCALAR" ->
      case is_user_type(name) && !is_builtin(name) {
        False -> Ok(IgnoredDef(kind: kind, name: name))
        True ->
          case string.ends_with(name, "ID") {
            True -> {
              let inner = string.drop_end(name, 2)
              Ok(BoxDef(name: name, inner_type: inner))
            }
            False -> Ok(ScalarDef(name: name, description: desc))
          }
      }
    "INPUT_OBJECT" ->
      case is_user_type(name) {
        False -> Ok(IgnoredDef(kind: kind, name: name))
        True -> {
          use fields_dyn <- result.try(decode.run(
            dyn,
            decode.at(["inputFields"], decode.list(decode.dynamic)),
          ))
          use fields <- result.try(
            result.all(list.map(fields_dyn, decode_input_field)),
          )
          Ok(InputDef(name: name, description: desc, fields: fields))
        }
      }
    _ -> Ok(IgnoredDef(kind: kind, name: name))
  }
}

fn schema_decoder() -> decode.Decoder(#(String, List(TypeDef))) {
  let query_name_decoder =
    decode.at(["__schema", "queryType", "name"], decode.string)
  let types_decoder =
    decode.at(["__schema", "types"], decode.list(decode.dynamic))
  use query_type_name <- decode.then(query_name_decoder)
  use types_dyn <- decode.then(types_decoder)
  let type_defs_result =
    types_dyn
    |> list.map(decode_type_def)
    |> result.all
  case type_defs_result {
    Error(_) -> decode.failure(#("", []), "TypeDef list")
    Ok(type_defs) ->
      decode.success(#(
        query_type_name,
        list.filter(type_defs, fn(td) {
          case td {
            IgnoredDef(_, _) -> False
            _ -> True
          }
        }),
      ))
  }
}

pub fn decode_schema(
  json_str: String,
) -> Result(#(String, List(TypeDef)), String) {
  json.parse(json_str, schema_decoder())
  |> result.map_error(fn(err) { string.inspect(err) })
}

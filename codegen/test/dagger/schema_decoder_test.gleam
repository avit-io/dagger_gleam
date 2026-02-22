import dagger/schema_decoder.{decode_type_ref}
import dagger/types.{type TypeRef, ListOf, Named, NonNull}
import gleam/dynamic/decode
import gleam/json
import gleeunit/should

fn parse_type_ref(json_str: String) -> Result(TypeRef, _) {
  let assert Ok(dyn) = json.parse(json_str, decode.dynamic)
  decode_type_ref(dyn)
}

pub fn decode_scalar_test() {
  parse_type_ref("{\"kind\":\"SCALAR\",\"name\":\"String\",\"ofType\":null}")
  |> should.equal(Ok(Named("String")))
}

pub fn decode_object_test() {
  parse_type_ref("{\"kind\":\"OBJECT\",\"name\":\"Container\",\"ofType\":null}")
  |> should.equal(Ok(Named("Container")))
}

pub fn decode_non_null_test() {
  parse_type_ref(
    "{\"kind\":\"NON_NULL\",\"name\":null,\"ofType\":{\"kind\":\"SCALAR\",\"name\":\"String\",\"ofType\":null}}",
  )
  |> should.equal(Ok(NonNull(Named("String"))))
}

pub fn decode_list_test() {
  parse_type_ref(
    "{\"kind\":\"LIST\",\"name\":null,\"ofType\":{\"kind\":\"SCALAR\",\"name\":\"String\",\"ofType\":null}}",
  )
  |> should.equal(Ok(ListOf(Named("String"))))
}

pub fn decode_non_null_list_non_null_test() {
  parse_type_ref(
    "{\"kind\":\"NON_NULL\",\"name\":null,\"ofType\":{\"kind\":\"LIST\",\"name\":null,\"ofType\":{\"kind\":\"NON_NULL\",\"name\":null,\"ofType\":{\"kind\":\"SCALAR\",\"name\":\"String\",\"ofType\":null}}}}",
  )
  |> should.equal(Ok(NonNull(ListOf(NonNull(Named("String"))))))
}

pub fn decode_minimal_test() {
  let json_str =
    "{\"__schema\":{
      \"queryType\":{\"name\":\"Query\"},
      \"types\":[
        {\"kind\":\"OBJECT\",\"name\":\"Query\",\"description\":\"root\",\"fields\":[],\"inputFields\":[],\"interfaces\":[],\"enumValues\":[]},
        {\"kind\":\"OBJECT\",\"name\":\"Test\",\"description\":\"desc\",\"fields\":[],\"inputFields\":[],\"interfaces\":[],\"enumValues\":[]}]
    }}"
  schema_decoder.decode_schema(json_str)
  |> should.be_ok
}

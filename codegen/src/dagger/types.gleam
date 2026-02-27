import gleam/option.{type Option}

pub type TypeRef {
  Named(name: String)
  ListOf(of: TypeRef)
  NonNull(of: TypeRef)
}

pub type TypeDef {
  ObjectDef(name: String, description: Option(String), fields: List(FieldDef))
  EnumDef(name: String, description: Option(String), values: List(String))
  ScalarDef(name: String, description: Option(String))
  // scalari custom reali
  AliasedDef(name: String, target: TypeRef)
  // alias di tipi noti
  BoxDef(name: String, inner_type: String)
  // per gestire e rappresentare i contenitorri come]
  // DirectoryID, SecretID, FileID
  InputDef(name: String, description: Option(String), fields: List(InputField))
  IgnoredDef(kind: String, name: String)
}

pub type InputField {
  InputField(name: String, description: Option(String), type_: TypeRef)
}

pub type FieldDef {
  FieldDef(
    name: String,
    description: Option(String),
    arguments: List(ArgDef),
    return_type: TypeRef,
  )
}

pub type ArgDef {
  ArgDef(name: String, description: Option(String), type_: TypeRef)
}

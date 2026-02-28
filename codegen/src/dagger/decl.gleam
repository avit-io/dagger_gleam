// =============================================================================
// DECL - Strutture intermedie per la generazione di codice Gleam
// =============================================================================
// Separa la fase di risoluzione (encoder) dalla fase di stampa (printer).
// Tutte le informazioni necessarie per la stampa sono già risolte qui.
// =============================================================================

/// Un modulo Gleam completo da generare.
pub type ModuleDecl {
  ModuleDecl(
    name: String,
    opts: List(OptDecl),
    functions: List(FunctionDecl),
    // Tipi phantom da emettere: (type_name, variants)
    // variants=[] → pub type ForFoo
    // variants=[..] → pub type FooFns { ForFn1 | ForFn2 | ... }
    phantom_decls: List(#(String, List(String))),
  )
}

/// Una variante dell'Opt type per un argomento opzionale.
pub type OptDecl {
  OptDecl(
    variant_name: String,
    arg_name: String,
    gleam_type: String,
    gql_value: String,
    // True → setter polimorfico: fn(Opts(a), T) -> Opts(a)
    // False → setter specifico: fn(Opts(tag), T) -> Opts(tag)
    universal: Bool,
    // Nome del tipo phantom da usare nel setter ("a" se universal, "ForFoo"/"FooFns" altrimenti)
    tag: String,
  )
}

/// Una funzione pubblica da generare nel modulo.
pub type FunctionDecl {
  FunctionDecl(
    name: String,
    docs: String,
    // Lista parametri già formattata, senza "pub fn name(" e senza ") ->"
    signature: String,
    // "t.Container" per chain, "a" per CPS/selection
    return_type: String,
    body: BodyKind,
    // variant_name degli OptDecl che questa funzione usa (per generare il suo encoder privato)
    relevant_opts: List(String),
    // Nome del tipo phantom per Opts: "ForFoo", "FooFns", "a" (polimorfico), "" (nessun opt)
    opt_tag: String,
  )
}

/// Il tipo di corpo della funzione, con tutti i valori già risolti.
pub type BodyKind {
  /// Funzione che restituisce un tipo oggetto (catena di operazioni).
  /// parent=True  → object method: usa "use q <- types.bind(parent.op)"
  /// parent=False → dag/constructor: usa "types.Pure([field])"
  Chain(
    gql_field: String,
    gql_args: String,
    return_type_name: String,
    parent: Bool,
  )
  /// Funzione terminale CPS (scalare, enum) — esegue la query.
  /// parent=True  → usa "parent.op" come query_expr
  /// parent=False → usa "types.Pure([])" come query_expr
  Cps(
    gql_field: String,
    gql_args: String,
    decoder: String,
    pure_ok: String,
    parent: Bool,
  )
  /// Funzione di selezione — lista di oggetti, CPS con select.
  /// parent=True  → usa "parent.op" come query_expr
  /// parent=False → usa "types.Pure([])" come query_expr
  Selection(
    gql_field: String,
    gql_args: String,
    inner_type: String,
    parent: Bool,
  )
}

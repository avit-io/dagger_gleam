import gleam/io
import gleam/string
import gleeunit/should

import dagger/client as dagger

pub fn connection_test() {
  use client <- dagger.connect()

  client
  |> dagger.raw_query("{ version }")
  // Testiamo il "battito cardiaco" del motore
  |> should.be_ok()

  client
  |> dagger.raw_query("{ __schema { types { name } } }")
  |> should.be_ok()
}

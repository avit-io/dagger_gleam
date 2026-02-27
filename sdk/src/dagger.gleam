import dagger/client
import dagger/types

pub fn connect(callback: fn(types.Client) -> a) -> a {
  client.connect(callback)
}

pub type Client =
  types.Client

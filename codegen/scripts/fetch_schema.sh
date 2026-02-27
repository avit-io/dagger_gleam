#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SCRIPT_DIR/../src/dagger/schema.generated.json"
dagger query --progress dots <<'EOF' | jq . > "$OUTPUT"
{
  __schema {
    queryType { name }
    types {
      name
      kind
      description
      fields {
        name
        description
        type {
          name kind
          ofType {
            name kind
            ofType {
              name kind
              ofType {
                name kind
                ofType {
                  name kind
                }
              }
            }
          }
        }
        args {
          name
          description
          type {
            name kind
            ofType {
              name kind
              ofType {
                name kind
                ofType {
                  name kind
                  ofType {
                    name kind
                  }
                }
              }
            }
          }
        }
      }
      enumValues {
        name
      }
      inputFields {
        name
        description
        type {
          name kind
          ofType {
            name kind
            ofType {
              name kind
              ofType {
                name kind
                ofType {
                  name kind
                }
              }
            }
          }
        }
      }
    }
  }
}
EOF

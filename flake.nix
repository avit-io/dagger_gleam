{
  description = "Idiomatic Gleam SDK for Dagger";
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    dagger.url = "github:dagger/nix";
    dagger.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      dagger,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        claude-code = pkgs.callPackage ./nix/claude.nix { };

        dgl = pkgs.writeShellScriptBin "dgl" ''
          ROOT="$(git rev-parse --show-toplevel)"
          if ! ${pkgs.docker}/bin/docker info > /dev/null 2>&1; then
            echo "Error: Docker daemon not found or not accessible. Dagger needs Docker!"
            exit 1
          fi
          case "$1" in
            generate)
              bash "$ROOT/codegen/scripts/fetch_schema.sh"
              cd "$ROOT/codegen" && gleam run -m dagger_codegen
              ;;
            test)
              cd "$ROOT/sdk" && dagger run --progress=plain gleam test
              ;;
            ci)
              bash "$ROOT/codegen/scripts/fetch_schema.sh" &&
              cd "$ROOT/codegen" && gleam run -m dagger_codegen &&
              cd "$ROOT/sdk" && dagger run --progress=plain gleam test
              ;;
            *)
              echo "Usage: dgl <generate|test|ci>"
              exit 1
              ;;
          esac
        '';

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.gleam.enable = true;
        };

        devInputs = [
          pkgs.gleam
          pkgs.erlang
          pkgs.jq
          pkgs.docker-client
          dagger.packages.${system}.dagger
          pkgs.nodejs_24
          dgl
        ];

      in
      {
        devShells = {
          default = pkgs.mkShell {
            buildInputs = devInputs ++ [ claude-code ];
          };
          ci = pkgs.mkShell {
            buildInputs = devInputs;
          };
        };
        formatter = treefmtEval.config.build.wrapper;
        checks.formatting = treefmtEval.config.build.check self;
      }
    );
}

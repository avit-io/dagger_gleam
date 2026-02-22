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

        dgl = pkgs.writeShellScriptBin "dgl" ''
          case "$1" in
            generate)
              gleam run -m dagger_codegen
              ;;
            test)
              gleam test
              ;;
            *)
              echo "Usage: dgl <generate|test>"
              exit 1
              ;;
          esac
        '';

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.gleam.enable = true;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.gleam
            pkgs.erlang
            dagger.packages.${system}.dagger
            dgl
          ];
        };

        formatter = treefmtEval.config.build.wrapper;
        checks.formatting = treefmtEval.config.build.check self;
      }
    );
}

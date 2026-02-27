{
  system ? builtins.currentSystem,
  lib,
  fetchurl,
  stdenvNoCC,
  nodejs_24,
  makeWrapper,
}:
let
  version = "2.1.56";

  shaMap = {
    x86_64-linux = "sha256-uXzE+o1iOHJlVx5f3nvxm/xLGA1EbRuRqIcA41m5B7k=";
    aarch64-linux = "sha256-...";
    x86_64-darwin = "sha256-...";
    aarch64-darwin = "sha256-...";
  };
in
stdenvNoCC.mkDerivation {
  pname = "claude-code";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
    sha256 = shaMap.${system};
  };

  nativeBuildInputs = [ makeWrapper ];

  sourceRoot = "package";

  installPhase = ''
    mkdir -p $out/lib/claude-code $out/bin
    cp -r . $out/lib/claude-code

    makeWrapper ${nodejs_24}/bin/node $out/bin/claude \
      --add-flags "$out/lib/claude-code/cli.js"
  '';

  meta = {
    description = "Claude Code CLI by Anthropic";
    homepage = "https://github.com/anthropics/claude-code";
    license = lib.licenses.mit;
    mainProgram = "claude";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
}

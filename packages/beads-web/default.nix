{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.11.2";

  supportedPlatforms = {
    aarch64-darwin = {
      artifact = "darwin-arm64";
      hash = "sha256-6+4ddKilgMHFfSBSNCQNPl2jZDmNtWpQ99zKn2bWnkc=";
    };
    x86_64-linux = {
      artifact = "linux-x64";
      hash = "sha256-eDL5aAwQ41XK58YFirf7HLvImxR5PJeFr6WIzmS5IRE=";
    };
  };

  current =
    supportedPlatforms.${stdenv.hostPlatform.system}
      or (throw "beads-web: ${stdenv.hostPlatform.system} not supported; build platforms: ${toString (builtins.attrNames supportedPlatforms)}");
in
stdenv.mkDerivation {
  pname = "beads-web";
  inherit version;

  src = fetchurl {
    url = "https://github.com/weselow/beads-web/releases/download/v${version}/beads-web-${current.artifact}";
    inherit (current) hash;
  };

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    install -m755 $src $out/bin/beads-web
  '';

  meta = with lib; {
    description = "Visual Kanban UI for Beads CLI — real-time sync, epic tracking, GitOps";
    homepage = "https://github.com/weselow/beads-web";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "beads-web";
    platforms = builtins.attrNames supportedPlatforms;
  };
}

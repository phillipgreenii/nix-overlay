{
  lib,
  stdenvNoCC,
  sources,
}:

let
  current =
    {
      aarch64-darwin = sources.gascity-darwin-arm64;
      x86_64-linux = sources.gascity-linux-amd64;
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "gascity: ${stdenvNoCC.hostPlatform.system} not supported; build platforms: aarch64-darwin, x86_64-linux");
in
stdenvNoCC.mkDerivation {
  pname = "gascity";
  inherit (current) version;
  inherit (current) src;

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/bin
    install -m755 gc $out/bin/gc
  '';

  meta = with lib; {
    description = "Orchestration-builder SDK for multi-agent systems";
    homepage = "https://github.com/gastownhall/gascity";
    license = licenses.mit;
    mainProgram = "gc";
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
  };
}

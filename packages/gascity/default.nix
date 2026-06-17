{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "1.2.1";

  supportedPlatforms = {
    aarch64-darwin = {
      artifact = "darwin_arm64";
      hash = "sha256-xJ82ow1PdV0VSRI/ufx5NNwApf7BeffUBI0UF2pfD6s=";
    };
    x86_64-linux = {
      artifact = "linux_amd64";
      hash = "sha256-erwm2CaIHTghlgDiXnigo2gC7d+ebtdwRidfXsnnIXI=";
    };
  };

  current =
    supportedPlatforms.${stdenv.hostPlatform.system}
      or (throw "gascity: ${stdenv.hostPlatform.system} not supported; build platforms: ${toString (builtins.attrNames supportedPlatforms)}");
in
stdenvNoCC.mkDerivation {
  pname = "gascity";
  inherit version;

  src = fetchurl {
    url = "https://github.com/gastownhall/gascity/releases/download/v${version}/gascity_${version}_${current.artifact}.tar.gz";
    hash = current.hash;
  };

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
    platforms = builtins.attrNames supportedPlatforms;
  };
}

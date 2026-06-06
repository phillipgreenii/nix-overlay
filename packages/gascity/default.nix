{ lib, pkgs }:

let
  version = "1.2.1";

  platform =
    {
      aarch64-darwin = "darwin_arm64";
      x86_64-darwin = "darwin_amd64";
      x86_64-linux = "linux_amd64";
      aarch64-linux = "linux_arm64";
    }
    .${pkgs.stdenv.hostPlatform.system}
      or (throw "gascity: unsupported system ${pkgs.stdenv.hostPlatform.system}");

  hashes = {
    darwin_arm64 = "sha256-xJ82ow1PdV0VSRI/ufx5NNwApf7BeffUBI0UF2pfD6s=";
    linux_amd64 = "sha256-erwm2CaIHTghlgDiXnigo2gC7d+ebtdwRidfXsnnIXI=";
    darwin_amd64 = lib.fakeHash;
    linux_arm64 = lib.fakeHash;
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "gascity";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/gastownhall/gascity/releases/download/v${version}/gascity_${version}_${platform}.tar.gz";
    hash =
      hashes.${platform}
        or (throw "gascity: no hash for ${platform}; run nix-prefetch-url on that platform");
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
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}

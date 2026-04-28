{ lib, pkgs }:
let
  version = "0.8.1";

  arch =
    {
      aarch64-darwin = "aarch64";
      x86_64-darwin = "x86_64";
    }
    .${pkgs.stdenv.hostPlatform.system}
      or (throw "c9watch: unsupported system ${pkgs.stdenv.hostPlatform.system}");

  cliHashAarch64 = "sha256-eoPZVa6C5obU+n2htn3buhdHPRsQtlECjl4MFby6bY8=";
  cliHashX86_64 = "sha256-sNhu818VAosCWX7BKEXJunwuVeBloFzQ0EOFg6VhNYc=";

  cliHashes = {
    aarch64 = cliHashAarch64;
    x86_64 = cliHashX86_64;
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "c9watch-cli";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/minchenlee/c9watch/releases/download/v${version}/c9watch-cli-${arch}-apple-darwin.tar.gz";
    hash = cliHashes.${arch};
  };

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/bin
    install -m755 c9watch $out/bin/c9watch
  '';

  meta = with lib; {
    description = "CLI companion for c9watch monitoring dashboard";
    homepage = "https://github.com/minchenlee/c9watch";
    license = licenses.mit;
    platforms = platforms.darwin;
  };
}

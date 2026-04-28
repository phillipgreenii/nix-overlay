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

  guiHashAarch64 = "sha256-o++hhIR5LeWcuFH34twVcQTVfWdrtqtHiZpN7g1hBnI=";
  guiHashX86_64 = "sha256-Zy/ggj9l+Cf3MC0kVa732lKD/7sZRhIjmulZLFOfo80=";

  guiHashes = {
    aarch64 = guiHashAarch64;
    x86_64 = guiHashX86_64;
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "c9watch";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/minchenlee/c9watch/releases/download/v${version}/c9watch_v${version}_${arch}.app.tar.gz";
    hash = guiHashes.${arch};
  };

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/Applications
    cp -r c9watch.app $out/Applications/
    chmod +x "$out/Applications/c9watch.app/Contents/MacOS/c9watch"
    /usr/bin/codesign --force --deep --sign - "$out/Applications/c9watch.app"
  '';

  meta = with lib; {
    description = "Real-time monitoring dashboard for Claude Code sessions";
    homepage = "https://github.com/minchenlee/c9watch";
    license = licenses.mit;
    platforms = platforms.darwin;
  };
}

{ lib, pkgs }:
pkgs.stdenvNoCC.mkDerivation rec {
  pname = "cmux";
  version = "0.64.1";

  src = pkgs.fetchurl {
    url = "https://github.com/manaflow-ai/cmux/releases/download/v${version}/cmux-macos.dmg";
    hash = "sha256-4b4oLb91irb8Jnl7n2xZ4xNUt8zY74+1n6prjoLpW3s=";
  };

  nativeBuildInputs = [ ];

  unpackPhase = ''
    mnt=$(mktemp -d)
    /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$src"
    cp -r "$mnt"/*.app .
    /usr/bin/hdiutil detach "$mnt"
  '';

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/Applications $out/bin
    cp -r *.app $out/Applications/
    ln -s $out/Applications/cmux.app/Contents/Resources/bin/cmux $out/bin/cmux
    ln -s $out/Applications/cmux.app/Contents/Resources/bin/claude $out/bin/cmux-claude
  '';

  meta = with lib; {
    description = "Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents";
    homepage = "https://github.com/manaflow-ai/cmux";
    license = licenses.agpl3Plus;
    platforms = platforms.darwin;
  };
}

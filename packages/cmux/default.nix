{
  lib,
  stdenvNoCC,
  _7zz,
  sources,
}:
stdenvNoCC.mkDerivation {
  pname = "cmux";
  inherit (sources.cmux) version src;

  # cmux 0.64.16 ships an APFS-formatted .dmg; `undmg` only supports HFS+
  # images (fails with "only HFS file systems are supported"). 7-Zip reads
  # APFS, so extract with `7zz` instead.
  nativeBuildInputs = [ _7zz ];

  unpackPhase = ''
    runHook preUnpack
    7zz x "$src"
    runHook postUnpack
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
    platforms = [ "aarch64-darwin" ];
  };
}

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

    # 7zz cannot restore macOS extended attributes, so it materializes each
    # one as a sidecar file named `<file>:<xattr>`. cmux signs its non-Mach-O
    # helper scripts (Contents/Resources/bin/{cmux-claude-wrapper,grok,open})
    # by storing the signature in `com.apple.cs.*` xattrs, which 7zz turns into
    # stray files. Those files are not part of the notarized CodeResources
    # seal, so Gatekeeper rejects the bundle ("a sealed resource is missing or
    # invalid" -> "cmux.app is damaged and can't be opened"). Drop them so the
    # bundle matches its original seal again; the scripts stay sealed by their
    # content hash in CodeResources.
    find . -name '*:com.apple.cs.*' -delete

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

  meta = {
    description = "Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents";
    homepage = "https://github.com/manaflow-ai/cmux";
    # Prebuilt, notarized macOS .dmg — an Electron bundle carrying native
    # Mach-O binaries, not built from source here.
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    # GPL-3.0-or-later: upstream README states "cmux is open source under
    # GPL-3.0-or-later" and the repo LICENSE is GPLv3. Corrected from the
    # previous (unverified) agpl3Plus (pg2-4ehlt).
    license = lib.licenses.gpl3Plus;
    platforms = [ "aarch64-darwin" ];
  };
}

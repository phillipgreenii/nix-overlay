{
  lib,
  stdenvNoCC,
  _7zz,
  makeBinaryWrapper,
  sources,
}:
stdenvNoCC.mkDerivation {
  pname = "cmux";
  inherit (sources.cmux) version src;

  # cmux ships an APFS-formatted .dmg; `undmg` only supports HFS+
  # images (fails with "only HFS file systems are supported"). 7-Zip reads
  # APFS, so extract with `7zz` instead.
  nativeBuildInputs = [
    _7zz
    makeBinaryWrapper
  ];

  # Extract with the flags nixpkgs' shared `_7zz` setup hook uses:
  #   -sns-  do not store NTFS alternate streams. 7zz would otherwise write each
  #          macOS extended attribute as a stray `<file>:com.apple.*` sidecar
  #          file, which is not part of the notarized CodeResources seal and
  #          makes Gatekeeper reject the bundle ("cmux.app is damaged").
  #   -snld  allow symlinks whose target stays inside the extraction folder.
  #          Since 0.65.1 the app bundle holds relative links such as
  #          `Resources/bin/PostHog_PostHog.bundle -> ../PostHog_PostHog.bundle`,
  #          which plain `7zz x` rejects ("Dangerous link path was ignored").
  # `-snld` also lets the DMG's top-level `Applications` link through; its
  # target is an absolute path into the extraction folder, so it is dropped
  # here (it is never installed) rather than left dangling in the store.
  unpackPhase = ''
    runHook preUnpack
    7zz x -sns- -snld "$src"

    if [ -L Applications ]; then
      rm Applications
    fi

    runHook postUnpack
  '';

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications $out/bin
    cp -r *.app $out/Applications/
    # Same layout as nixpkgs' cmux: bin/cmux launches the GUI app executable.
    # The command-line client is a different program inside the bundle
    # (Contents/Resources/bin/cmux); it is exposed by the cmux-cli package as
    # `cmux-cli`. The bundle's bin/claude helper is not linked: nothing in the
    # workspace used the former cmux-claude link.
    makeBinaryWrapper \
      "$out/Applications/cmux.app/Contents/MacOS/cmux" \
      "$out/bin/cmux"

    # Fail clearly if any link in the output points at an absolute path
    # outside the store output (the extraction tree is gone after the build).
    while IFS= read -r link; do
      target=$(readlink "$link")
      case "$target" in
        "$out"/*) ;;
        /*)
          echo "cmux: symlink $link has absolute target $target outside $out" >&2
          exit 1
          ;;
      esac
    done < <(find $out -type l)
    runHook postInstall
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

{
  lib,
  stdenvNoCC,
  _7zz,
  sources,
}:
stdenvNoCC.mkDerivation {
  pname = "logseq";
  inherit (sources.logseq) version src;

  # Logseq ships the desktop app as a .dmg. Same extractor choice as cmux and
  # eclipse-java: `undmg` cannot read these images, while `7zz` reads the image
  # filesystem directly.
  nativeBuildInputs = [ _7zz ];

  unpackPhase = ''
    runHook preUnpack
    7zz x "$src"

    # 7zz materializes macOS extended attributes it cannot restore as sidecar
    # files named `<file>:<xattr>`. This image carries 1140 alternate streams,
    # so — unlike eclipse-java, where the same line is a defensive no-op — the
    # cleanup is load-bearing here (as it is for cmux). Signatures stored in
    # `com.apple.cs.*` xattrs would otherwise become stray files that are NOT
    # part of the notarized CodeResources seal, and Gatekeeper would reject the
    # bundle ("a sealed resource is missing or invalid" -> "Logseq.app is
    # damaged and can't be opened"). Dropping them restores the original seal;
    # the sealed files stay covered by their content hash in CodeResources.
    find . -name '*:com.apple.cs.*' -delete

    runHook postUnpack
  '';

  sourceRoot = ".";
  # Do NOT let nix strip/patch the prebuilt, code-signed Mach-O binaries —
  # any rewrite invalidates the signature (same reason as cmux/eclipse-java).
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications

    # The image unpacks to a VERSIONED volume directory (`Logseq 2.0.1-arm64/`)
    # holding `Logseq.app`, so the bundle path embeds the version — glob it
    # instead of hardcoding a name that every release would break. Assert
    # exactly one match so an upstream layout change fails loudly here rather
    # than silently installing an empty $out.
    shopt -s nullglob
    apps=("Logseq "*-arm64/Logseq.app)
    if [ "''${#apps[@]}" -ne 1 ]; then
      echo "logseq: expected exactly 1 Logseq.app in the image, found ''${#apps[@]}: ''${apps[*]}" >&2
      exit 1
    fi
    cp -R "''${apps[0]}" $out/Applications/

    runHook postInstall
  '';

  # Shift-left: sandbox-safe structural assertions (file inspection only; the
  # app is NOT launched here — that is an out-of-sandbox smoke test). Runs on
  # every `nix build` / `nix flake check`. Deliberately no `$out/bin` entry:
  # Logseq is GUI-only here, with no headless/CLI use case like eclipse's
  # Gradle import or cmux's terminal launcher, so the app bundle is the whole
  # interface and dock registration consumes it directly.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    test -d "$out/Applications/Logseq.app"
    test -x "$out/Applications/Logseq.app/Contents/MacOS/Logseq"
    test -f "$out/Applications/Logseq.app/Contents/Info.plist"
    # The seal must have survived the xattr-sidecar cleanup above.
    test -f "$out/Applications/Logseq.app/Contents/_CodeSignature/CodeResources"
    # No leftover xattr sidecars anywhere in the installed bundle.
    ! find "$out/Applications/Logseq.app" -name '*:com.apple.cs.*' | grep -q .
    runHook postInstallCheck
  '';

  meta = {
    description = "Privacy-first, local-first outliner for knowledge management and note taking (2.x DB version)";
    homepage = "https://logseq.com";
    # Prebuilt, code-signed macOS .app bundle — an Electron app carrying native
    # Mach-O binaries, not built from source here.
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    # AGPL-3.0-only: verified against the repo's LICENSE.md (GNU Affero GPL v3)
    # and GitHub's SPDX detection, and matches nixpkgs' own `logseq` meta for
    # the same upstream. (Verified rather than assumed — an unverified license
    # claim is exactly what pg2-4ehlt corrected on cmux.)
    license = lib.licenses.agpl3Only;
    # Only the darwin-arm64 .dmg is repackaged here.
    platforms = [ "aarch64-darwin" ];
  };
}

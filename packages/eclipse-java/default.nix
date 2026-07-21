{
  lib,
  stdenvNoCC,
  _7zz,
  sources,
}:
stdenvNoCC.mkDerivation {
  pname = "eclipse-java";
  inherit (sources.eclipse-java) version src;

  # Eclipse ships its macOS EPP IDE as a .dmg. As with cmux, `undmg` cannot read
  # this image, so extract with `7zz` (7-Zip reads the image filesystem). The
  # archive unpacks to a top-level `Eclipse/` volume dir containing `Eclipse.app`
  # plus HFS private-data dirs and the drag-to-install `Applications` symlink.
  nativeBuildInputs = [ _7zz ];

  unpackPhase = ''
    runHook preUnpack
    7zz x "$src"

    # 7zz materializes macOS extended attributes it cannot restore as sidecar
    # files named `<file>:<xattr>`. Code-signing signatures stored in
    # `com.apple.cs.*` xattrs would become stray files that are NOT part of the
    # notarized CodeResources seal, so Gatekeeper would reject the bundle. Drop
    # them so the bundle matches its original seal again (same fix as cmux).
    # NOTE: for this EPP image 7zz on macOS restores the xattrs natively and
    # creates no sidecars, so this is a defensive no-op kept for parity with the
    # cmux model and in case sandbox 7zz behaves differently.
    find . -name '*:com.apple.cs.*' -delete

    runHook postUnpack
  '';

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications $out/bin
    # The image unpacks to `Eclipse/` (the volume name) holding `Eclipse.app`;
    # the sibling `Applications` entry is only the drag-to-install symlink.
    cp -R Eclipse/Eclipse.app $out/Applications/

    # $out/bin/eclipse is an exec WRAPPER, not a symlink (deviation from the
    # original spec, required for correctness): eclipse.ini uses paths relative
    # to the launcher (-startup/--launcher.library/-vm = ../Eclipse/...), and the
    # macOS Equinox launcher resolves them against the *invocation* path without
    # realpath'ing it. A `bin/eclipse` symlink would make the launcher look for
    # `$out/Eclipse/...` and exit 1 with no output. The wrapper execs the real
    # launcher by its absolute path (and does NOT rewrite argv[0], so the
    # launcher's own path-resolution sees Contents/MacOS and finds ../Eclipse).
    launcher="$out/Applications/Eclipse.app/Contents/MacOS/eclipse"
    {
      echo '#!/bin/sh'
      echo "exec \"$launcher\" \"\$@\""
    } > $out/bin/eclipse
    chmod +x $out/bin/eclipse
    runHook postInstall
  '';

  # Shift-left: sandbox-safe structural assertions (file inspection only; the
  # app is NOT launched here — that is the out-of-sandbox smoke test). Runs on
  # every `nix build`/`nix flake check`.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    test -d "$out/Applications/Eclipse.app"
    test -x "$out/Applications/Eclipse.app/Contents/MacOS/eclipse"
    # $out/bin/eclipse is an executable wrapper that execs the real launcher.
    test -x "$out/bin/eclipse"
    grep -q 'Contents/MacOS/eclipse' "$out/bin/eclipse"
    runHook postInstallCheck
  '';

  meta = {
    description = "Eclipse IDE for Java Developers (EPP), repackaged from the upstream macOS .dmg";
    homepage = "https://www.eclipse.org";
    # Prebuilt, code-signed macOS .app bundle carrying native Mach-O binaries and
    # a bundled JRE — not built from source here.
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    # Eclipse Public License 2.0 (the EPP distribution's license).
    license = lib.licenses.epl20;
    platforms = [ "aarch64-darwin" ];
  };
}

# Fix Firefox TCC permissions on macOS: use makeBinaryWrapper (compiled binary)
# instead of makeWrapper (bash script) so macOS attributes camera/mic
# permissions to "firefox" instead of "bash".
_: prev:
prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
  firefox = prev.firefox.overrideAttrs (
    oldAttrs:
    let
      sentinel = ''makeWrapper "$oldExe"'';
    in
    assert prev.lib.assertMsg (prev.lib.hasInfix sentinel oldAttrs.buildCommand) ''
      firefox-binary-wrapper overlay: upstream firefox buildCommand no longer
      contains the sentinel `${sentinel}`. The replaceStrings substitution would
      silently no-op, defeating the TCC permission fix. Re-audit nixpkgs'
      firefox wrapper and update this overlay.
    '';
    {
      nativeBuildInputs = oldAttrs.nativeBuildInputs ++ [
        prev.makeBinaryWrapper
        prev.rcodesign
      ];
      buildCommand =
        builtins.replaceStrings [ sentinel ] [ ''makeBinaryWrapper "$oldExe"'' ] oldAttrs.buildCommand
        + ''
          # Re-sign the .app bundle so macOS binds Info.plist and sealed resources
          # (firefox.icns, bundle ID) to the binary wrapper; without it TCC shows a
          # generic executable icon (pg2-1h7c, personal c408fe3). Acceptance
          # criterion and evidence: docs/adr/0002-firefox-binary-wrapper-rcodesign-signing.md.
          #
          # Sandbox-safe (bead pg2-inqwy): uses nixpkgs' rcodesign, never the host's
          # system codesign, so the build works with sandbox = true. nixpkgs'
          # sigtool codesign cannot sign a bundle (c7cb263 / 35c95f5). The flake
          # check firefox-binary-wrapper-no-system-codesign enforces this.
          #
          # The bundle's Contents/{MacOS,Resources,...} entries are symlinks into the
          # read-only firefox-unwrapped store path. Signing in place fails (EACCES
          # through the links), and sealing symlinks leaves a bundle that
          # `codesign --verify` rejects ("Too many levels of symbolic links"). So:
          # copy the bundle with every symlink resolved into a real file, sign that
          # copy to a SEPARATE output path, then swap it into $out.
          app="$out/Applications/Firefox.app"
          work="$TMPDIR/firefox-codesign"
          mkdir -p "$work/resolved" "$work/signed"
          cp -RL "$app" "$work/resolved/Firefox.app"
          chmod -R u+w "$work/resolved"
          rm -rf "$work/resolved/Firefox.app/Contents/_CodeSignature"
          rcodesign sign "$work/resolved/Firefox.app" "$work/signed/Firefox.app"
          chmod -R u+w "$app"
          rm -rf "$app"
          cp -R "$work/signed/Firefox.app" "$app"
        '';
    }
  );
}

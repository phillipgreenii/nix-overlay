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
      ];
      buildCommand =
        builtins.replaceStrings [ sentinel ] [ ''makeBinaryWrapper "$oldExe"'' ] oldAttrs.buildCommand
        + ''
          # Re-sign the .app bundle so macOS binds Info.plist and sealed resources
          # (icon, bundle ID) to the binary wrapper for correct TCC icon display.
          # codesign requires Info.plist to be a regular file, not a symlink.
          appDir="$out/Applications/Firefox.app/Contents"
          if [ -L "$appDir/Info.plist" ]; then
            target=$(readlink -f "$appDir/Info.plist")
            rm -f "$appDir/Info.plist"
            cp -f "$target" "$appDir/Info.plist"
          fi
          # Use the system codesign: sigtool's codesign (c7cb263) only signs
          # individual Mach-O files, so signing the .app *bundle* throws
          # SigTool::NotAMachOFileException. Real /usr/bin/codesign signs
          # bundles and is available here (nix sandbox = false). This re-impurifies
          # the build (the deepdive flagged hardcoded /usr/bin/codesign); the
          # proper sandbox-safe fix belongs to the overlay-rework initiative.
          /usr/bin/codesign --force --sign - "$out/Applications/Firefox.app"
        '';
    }
  );
}

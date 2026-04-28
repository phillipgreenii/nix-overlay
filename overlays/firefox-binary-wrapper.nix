# Fix Firefox TCC permissions on macOS: use makeBinaryWrapper (compiled binary)
# instead of makeWrapper (bash script) so macOS attributes camera/mic
# permissions to "firefox" instead of "bash".
_: prev:
prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
  firefox = prev.firefox.overrideAttrs (oldAttrs: {
    nativeBuildInputs = oldAttrs.nativeBuildInputs ++ [ prev.makeBinaryWrapper ];
    buildCommand =
      builtins.replaceStrings [ ''makeWrapper "$oldExe"'' ] [ ''makeBinaryWrapper "$oldExe"'' ]
        oldAttrs.buildCommand
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
        /usr/bin/codesign --force --sign - "$out/Applications/Firefox.app"
      '';
  });
}

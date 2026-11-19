# The cmux command-line client, exposed as `cmux-cli`.
#
# nixpkgs' cmux package installs `bin/cmux` as a wrapper around the app's GUI
# executable (Contents/MacOS/cmux); the scriptable CLI is a different program
# inside the same bundle (Contents/Resources/bin/cmux). So that callers can use
# either package, the CLI gets its own name here, and it is taken from the cmux
# package it is given so it always matches that app's version.
{
  lib,
  stdenvNoCC,
  cmux,
}:
stdenvNoCC.mkDerivation {
  pname = "cmux-cli";
  inherit (cmux) version;

  dontUnpack = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    ln -s ${cmux}/Applications/cmux.app/Contents/Resources/bin/cmux $out/bin/cmux-cli
    runHook postInstall
  '';

  meta = {
    description = "Command-line client of the cmux terminal (the CLI inside the cmux app bundle)";
    homepage = "https://github.com/manaflow-ai/cmux";
    license = lib.licenses.gpl3Plus;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "cmux-cli";
    platforms = [ "aarch64-darwin" ];
  };
}

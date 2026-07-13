{
  lib,
  stdenvNoCC,
  sources,
}:
stdenvNoCC.mkDerivation {
  pname = "bat-gherkin-syntax";
  inherit (sources.bat-gherkin-syntax) version;
  src = sources.bat-gherkin-syntax.src;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r . $out/
    runHook postInstall
  '';
  meta = {
    description = "Gherkin syntax for SublimeText, consumable by bat";
    homepage = "https://github.com/keith-hall/SublimeGherkinSyntax";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}

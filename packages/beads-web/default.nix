{
  lib,
  stdenv,
  sources,
}:

let
  current =
    {
      aarch64-darwin = sources.beads-web-darwin-arm64;
      x86_64-linux = sources.beads-web-linux-x64;
    }
    .${stdenv.hostPlatform.system}
      or (throw "beads-web: ${stdenv.hostPlatform.system} not supported; build platforms: aarch64-darwin, x86_64-linux");
in
stdenv.mkDerivation {
  pname = "beads-web";
  inherit (current) version;
  inherit (current) src;

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    install -m755 $src $out/bin/beads-web
  '';

  meta = with lib; {
    description = "Visual Kanban UI for Beads CLI — real-time sync, epic tracking, GitOps";
    homepage = "https://github.com/weselow/beads-web";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "beads-web";
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
  };
}

{ pkgs }:

let
  version = "0.10.1";

  platform =
    {
      aarch64-darwin = "darwin-arm64";
      x86_64-darwin = "darwin-x64";
      x86_64-linux = "linux-x64";
    }
    .${pkgs.stdenv.hostPlatform.system}
      or (throw "beads-web: unsupported system ${pkgs.stdenv.hostPlatform.system}");

  hashes = {
    darwin-arm64 = "sha256-r6IMAWAz8CZA77VTrjwCSqMjalacuIZRAuFh70mGbb0=";
  };
in
pkgs.stdenv.mkDerivation {
  pname = "beads-web";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/weselow/beads-web/releases/download/v${version}/beads-web-${platform}";
    hash =
      hashes.${platform}
        or (throw "beads-web: no hash for ${platform}; run nix-prefetch-url on that platform");
  };

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    install -m755 $src $out/bin/beads-web
  '';

  meta = with pkgs.lib; {
    description = "Visual Kanban UI for Beads CLI — real-time sync, epic tracking, GitOps";
    homepage = "https://github.com/weselow/beads-web";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "beads-web";
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
      "x86_64-linux"
    ];
  };
}

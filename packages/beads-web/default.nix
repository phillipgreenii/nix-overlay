{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.11.2";

  platform =
    {
      aarch64-darwin = "darwin-arm64";
      x86_64-darwin = "darwin-x64";
      x86_64-linux = "linux-x64";
    }
    .${stdenv.hostPlatform.system}
      or (throw "beads-web: unsupported system ${stdenv.hostPlatform.system}");

  hashes = {
    darwin-arm64 = "sha256-6+4ddKilgMHFfSBSNCQNPl2jZDmNtWpQ99zKn2bWnkc=";
    darwin-x64 = lib.fakeHash;
    linux-x64 = lib.fakeHash;
  };
in
stdenv.mkDerivation {
  pname = "beads-web";
  inherit version;

  src = fetchurl {
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

  meta = with lib; {
    description = "Visual Kanban UI for Beads CLI — real-time sync, epic tracking, GitOps";
    homepage = "https://github.com/weselow/beads-web";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "beads-web";
    platforms = platforms.unix;
  };
}

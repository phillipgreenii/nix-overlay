{
  lib,
  buildGo127Module,
  sources,
}:
let
  # nvfetcher pins the release tag verbatim (`vX.Y.Z`) because `fetch.github`
  # fetches rev `$ver` and pint's tags carry the `v`. Strip it for the
  # user-facing version and the `main.version` ldflag.
  version = lib.removePrefix "v" sources.pint.version;
in
# pint v0.88.0's go.mod requires go >= 1.27.0; nixpkgs' default `go` (via
# buildGoModule) is still 1.26.x on this branch and GOTOOLCHAIN=local blocks
# auto-fetching a newer toolchain during the sandboxed build. Pin the builder
# to the versioned buildGo127Module instead of overriding `go` by hand.
buildGo127Module {
  pname = "pint";
  inherit version;
  src = sources.pint.src;

  # pint has no in-tree `vendor/` dir; deps are fetched and vendored by nix.
  # Re-hashed for buildGo127Module (2026-09-12): the go1.27 module resolver
  # produced a different vendor tree than go1.26 did for the same go.sum.
  vendorHash = "sha256-JqA+2nGwdsQrx+NfVFTww1pcRCmbcrdsyK7Ixvvm14U=";

  subPackages = [ "cmd/pint" ];

  # pint is urfave/cli/v3: its version ldflag symbol is the lowercase package
  # main `version` var (see cmd/pint/main.go), not the mkGoBinary convention.
  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  # Skip upstream Go tests: they are slow and not needed to validate the
  # repackage; the nvfetcher-pinned SHA is the integrity proof.
  doCheck = false;

  meta = {
    description = "Prometheus rule linter/validator";
    homepage = "https://github.com/cloudflare/pint";
    license = lib.licenses.asl20;
    mainProgram = "pint";
    platforms = lib.platforms.unix;
  };
}

{
  lib,
  buildGoModule,
  sources,
}:
let
  # nvfetcher pins the release tag verbatim (`vX.Y.Z`) because `fetch.github`
  # fetches rev `$ver` and pint's tags carry the `v`. Strip it for the
  # user-facing version and the `main.version` ldflag.
  version = lib.removePrefix "v" sources.pint.version;
in
buildGoModule {
  pname = "pint";
  inherit version;
  src = sources.pint.src;

  # pint has no in-tree `vendor/` dir; deps are fetched and vendored by nix.
  vendorHash = "sha256-BjFX0RWvNQq6BCR24FpIWT2CTJkRK5mkg3kCEInGE2E=";

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

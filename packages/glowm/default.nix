{
  lib,
  buildGoModule,
  sources,
}:
let
  # nvfetcher pins the release tag verbatim (`vX.Y.Z`) because `fetch.github`
  # fetches rev `$ver` and glowm's tags carry the `v`. Strip it for the
  # user-facing version and the `main.version` ldflag (goreleaser convention).
  version = lib.removePrefix "v" sources.glowm.version;
in
buildGoModule {
  pname = "glowm";
  inherit version;
  src = sources.glowm.src;

  # glowm has no in-tree `vendor/` dir; deps are fetched and vendored by nix.
  vendorHash = "sha256-9Wg6WvXJWS1NTJsXFAMsIHTaeDzVzmdzuqS+uksJ2Ig=";

  subPackages = [ "cmd/glowm" ];

  # goreleaser sets `-X main.version={{.Version}}`.
  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  # Skip upstream Go tests: slow, not needed to validate the repackage, and
  # some exercise Chrome (chromedp). The nvfetcher-pinned SHA is the integrity
  # proof.
  doCheck = false;

  meta = {
    description = "Terminal-first Markdown viewer with inline Mermaid rendering";
    homepage = "https://github.com/atani/glowm";
    license = lib.licenses.mit;
    mainProgram = "glowm";
    platforms = lib.platforms.unix;
  };
}

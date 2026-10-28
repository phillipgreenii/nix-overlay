{
  lib,
  buildGoModule,
  sources,
}:
buildGoModule {
  pname = "gh-stack";
  version = lib.removePrefix "v" sources.gh-stack.version;
  src = sources.gh-stack.src;

  vendorHash = "sha256-TC1mSXYjOQo00fb2yuGdk1rl6z6rp0WT3AmzXomPzis=";

  # Without this the binary reports "gh stack version dev" (cmd.Version's
  # default), so the version smoke test (flake checks.gh-stack-version) could
  # not tell a correct build from a stale one. Upstream's release workflow
  # sets the same symbol.
  ldflags = [
    "-s"
    "-w"
    "-X github.com/github/gh-stack/cmd.Version=${lib.removePrefix "v" sources.gh-stack.version}"
  ];

  doCheck = false;

  meta = {
    description = "GitHub CLI extension for managing stacked branches and pull requests";
    homepage = "https://github.com/github/gh-stack";
    license = lib.licenses.mit;
    mainProgram = "gh-stack";
    platforms = lib.platforms.unix;
  };
}

{
  lib,
  sources,
}:
# Bare fetchFromGitHub result with smuggled meta (deepdive B8 — deferred).
# The // merge re-applies meta on top of the source derivation. If
# `nix build .#bat-gherkin-syntax` fails because the // drops derivation
# markers, swap to:
#   sources.bat-gherkin-syntax.src.overrideAttrs (_: {
#     meta = { platforms = lib.platforms.unix; };
#   })
sources.bat-gherkin-syntax.src
// {
  meta = {
    platforms = lib.platforms.unix;
  };
}

{
  lib,
  buildGoModule,
  sources,
}:
buildGoModule {
  pname = "gh-stack";
  version = lib.removePrefix "v" sources.gh-stack.version;
  src = sources.gh-stack.src;

  vendorHash = "sha256-CxsHRC5AbApxcsavyaBmoPtTUHy5jlaQ7BLvgE6mJJ4=";

  doCheck = false;

  meta = {
    description = "GitHub CLI extension for managing stacked branches and pull requests (private preview)";
    homepage = "https://github.com/github/gh-stack";
    license = lib.licenses.mit;
    mainProgram = "gh-stack";
    platforms = lib.platforms.unix;
  };
}

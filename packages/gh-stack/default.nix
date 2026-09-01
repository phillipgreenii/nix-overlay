{
  lib,
  buildGoModule,
  sources,
}:
buildGoModule {
  pname = "gh-stack";
  version = lib.removePrefix "v" sources.gh-stack.version;
  src = sources.gh-stack.src;

  vendorHash = "sha256-0Xtr/MOpX4u5GnbRdNxKPA0GpSzi8PIbVc9MmP05De4=";

  doCheck = false;

  meta = {
    description = "GitHub CLI extension for managing stacked branches and pull requests (private preview)";
    homepage = "https://github.com/github/gh-stack";
    license = lib.licenses.mit;
    mainProgram = "gh-stack";
    platforms = lib.platforms.unix;
  };
}

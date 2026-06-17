{
  lib,
  tmuxPlugins,
  fetchFromGitHub,
}:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-mouse-swipe";
  version = "unstable-2025-12-29";
  src = fetchFromGitHub {
    owner = "jaclu";
    repo = "tmux-mouse-swipe";
    rev = "8667851876c7591c668f29df6a142271051a3e2d";
    sha256 = "sha256-0Mh0sQm3GP1V/KlYi6VjD3Zx2ssLwVI5uOnOp67trYk=";
  };
  meta = {
    platforms = lib.platforms.unix;
  };
}

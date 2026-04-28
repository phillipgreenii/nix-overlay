{ pkgs }:
pkgs.tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-mouse-swipe";
  version = "unstable-2025-12-29";
  src = pkgs.fetchFromGitHub {
    owner = "jaclu";
    repo = "tmux-mouse-swipe";
    rev = "main";
    sha256 = "sha256-0Mh0sQm3GP1V/KlYi6VjD3Zx2ssLwVI5uOnOp67trYk=";
  };
}

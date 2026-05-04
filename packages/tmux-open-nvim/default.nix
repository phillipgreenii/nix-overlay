{ lib, pkgs }:
pkgs.tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-open-nvim";
  version = "unstable-2026-04-20";
  src = pkgs.fetchFromGitHub {
    owner = "trevarj";
    repo = "tmux-open-nvim";
    rev = "master";
    sha256 = "sha256-lftDhRERenGVDTWFP1o/bfZIk0RsHh2PxoYY8j8/9CQ=";
  };
  meta = {
    platforms = lib.platforms.unix;
  };
}

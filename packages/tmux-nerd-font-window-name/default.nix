{ pkgs }:
pkgs.tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-nerd-font-window-name";
  version = "unstable-2026-04-10";
  src = pkgs.fetchFromGitHub {
    owner = "joshmedeski";
    repo = "tmux-nerd-font-window-name";
    rev = "main";
    sha256 = "sha256-b6CQdN33hU5li/0LUOHMs7oN8ffVRVQlSf17Twhz2e8=";
  };
}

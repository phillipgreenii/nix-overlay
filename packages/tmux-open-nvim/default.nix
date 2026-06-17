{
  lib,
  tmuxPlugins,
  fetchFromGitHub,
}:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-open-nvim";
  version = "unstable-2026-04-20";
  src = fetchFromGitHub {
    owner = "trevarj";
    repo = "tmux-open-nvim";
    rev = "d140ac66e24f1cd26b68638da01a82717a1921bd";
    sha256 = "sha256-lftDhRERenGVDTWFP1o/bfZIk0RsHh2PxoYY8j8/9CQ=";
  };
  meta = {
    platforms = lib.platforms.unix;
  };
}

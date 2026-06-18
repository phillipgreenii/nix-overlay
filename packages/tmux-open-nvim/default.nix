{
  lib,
  tmuxPlugins,
  sources,
}:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-open-nvim";
  version = "unstable-${sources.tmux-open-nvim.date}";
  src = sources.tmux-open-nvim.src;
  meta = {
    platforms = lib.platforms.unix;
  };
}

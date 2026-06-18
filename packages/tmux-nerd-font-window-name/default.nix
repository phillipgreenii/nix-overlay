{
  lib,
  tmuxPlugins,
  sources,
}:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-nerd-font-window-name";
  version = "unstable-${sources.tmux-nerd-font-window-name.date}";
  src = sources.tmux-nerd-font-window-name.src;
  meta = {
    platforms = lib.platforms.unix;
  };
}

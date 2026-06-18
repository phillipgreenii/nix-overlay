{
  lib,
  tmuxPlugins,
  sources,
}:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-mouse-swipe";
  version = "unstable-${sources.tmux-mouse-swipe.date}";
  src = sources.tmux-mouse-swipe.src;
  meta = {
    platforms = lib.platforms.unix;
  };
}

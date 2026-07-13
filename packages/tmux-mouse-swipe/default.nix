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
    description = "tmux plugin: right-click and swipe to switch windows or sessions";
    homepage = "https://github.com/jaclu/tmux-mouse-swipe";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}

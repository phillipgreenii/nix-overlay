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
    description = "tmux plugin that adds Nerd Font icons to window names";
    homepage = "https://github.com/joshmedeski/tmux-nerd-font-window-name";
    # Upstream ships no LICENSE file at the pinned rev; license intentionally
    # omitted rather than guessed (pg2-4ehlt).
    platforms = lib.platforms.unix;
  };
}

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
    description = "tmux plugin to open files in a Neovim pane";
    homepage = "https://github.com/trevarj/tmux-open-nvim";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.unix;
  };
}

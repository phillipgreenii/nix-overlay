{
  callPackage,
  yaziPlugins,
  sources,
}:
let
  # Reuse nixpkgs' own builder (pkgs.yaziPlugins.mkYaziPlugin) instead of the
  # former local reimplementation, which cp -r'd the whole repo with no layout
  # validation and drifted from upstream (pg2-ztb6l).
  inherit (yaziPlugins) mkYaziPlugin;
  callPlugin = path: callPackage path { inherit mkYaziPlugin sources; };
in
{
  icons-brew = callPlugin ./icons-brew;
  bunny = callPlugin ./bunny;
}

{
  description = "Third-party Nix packages absent from or outdated in nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    flake-parts.url = "github:hercules-ci/flake-parts";
    phillipgreenii-nix-base = {
      url = "github:phillipgreenii/nix-repo-base";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Mirror flake-utils.lib.defaultSystems verbatim — do NOT drop x86_64-darwin.
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      imports = [
        # pre-commit transitively imports treefmt
        inputs.phillipgreenii-nix-base.flakeModules.pre-commit
        inputs.phillipgreenii-nix-base.flakeModules.devshell
        inputs.phillipgreenii-nix-base.flakeModules.checks
      ];

      # Top-level option — see nix-repo-base/flake-modules/devshell.nix:7.
      # KNOWN LIMITATION: this option is a flat `listOf package` evaluated once;
      # hardcoding x86_64-linux means the devshell only works correctly on
      # x86_64-linux. nix-overlay's primary dev host is Linux. Track a
      # producer-side follow-up bead to make this option per-system-aware.
      phillipgreenii.devshell.extraInputs = with nixpkgs.legacyPackages.x86_64-linux; [
        jq
        curl
        gnused
        nvfetcher
      ];

      # nvfetcher's _sources/ is generated (not hand-written); deadnix flags its
      # unused fetcher args. The producer merges extraHooks over its hook set, so
      # override the deadnix hook to exclude the generated tree. (treefmt excludes
      # it via settings.global.excludes in perSystem.) Surfaced post-migration; tc-xbxex.
      phillipgreenii.pre-commit.extraHooks.deadnix = {
        enable = true;
        name = "deadnix";
        excludes = [ "^_sources/" ];
      };

      perSystem =
        {
          pkgs,
          config,
          ...
        }:
        let
          yaziPluginSet = pkgs.callPackage ./packages/yaziPlugins { };
        in
        {
          # formatter, devShells.default, packages.install-pre-commit-hooks,
          # checks.{formatting, linting, pre-commit, consumer-input-alignment}
          # — all auto-contributed.

          # The producer treefmt runs prettier on *.json; nvfetcher's source
          # manifests are generated (not hand-formatted) and would fight it.
          # The old local treefmt.nix never enabled prettier, so this only
          # surfaced after the flake-parts migration adopted the producer module.
          treefmt.settings.global.excludes = [
            "_sources/generated.json"
            "_sources/generated.nix"
          ];

          # Build every package as a check. Use config.packages (same-perSystem
          # scope) rather than self.packages.${system} which forces an eval
          # cycle through flake-parts' mkPerSystemFile.
          checks = config.packages;

          packages =
            let
              extended = pkgs.extend self.overlays.default;
            in
            {
              inherit (extended.phillipgreenii)
                beads-web
                bat-gherkin-syntax
                ;
              inherit (extended.tmuxPlugins)
                tmux-open-nvim
                tmux-mouse-swipe
                tmux-nerd-font-window-name
                ;
              yaziPlugins-icons-brew = extended.yaziPlugins.icons-brew;
              yaziPlugins-bunny = extended.yaziPlugins.bunny;

              fix-lint = pkgs.writeShellScriptBin "fix-lint" ''
                exec ${pkgs.lib.getExe pkgs.statix} fix "''${@:-.}"
              '';
              # install-pre-commit-hooks REMOVED — pre-commit module auto-contributes it.
            }
            // pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin") {
              inherit (extended.phillipgreenii) cmux;
            };

          legacyPackages = {
            yaziPlugins = { inherit (yaziPluginSet) icons-brew bunny; };
          };
        };

      flake = {
        # Shape-B wrapper: imports the producer's HM module and sets options
        # with this flake's self + name. Downstream consumers see the configured
        # module shape (no further options to set).
        homeModules.install-metadata = { ... }: {
          imports = [ inputs.phillipgreenii-nix-base.homeModules.install-metadata ];
          phillipgreenii.install-metadata = {
            flakeSelf = self;
            name = "phillipgreenii-nix-overlay";
          };
        };

        overlays.firefox-binary-wrapper = import ./overlays/firefox-binary-wrapper.nix;

        overlays.default =
          final: prev:
          let
            sources = final.callPackage ./_sources/generated.nix { };
          in
          {
            phillipgreenii = {
              beads-web = final.callPackage ./packages/beads-web { inherit sources; };
              bat-gherkin-syntax = final.callPackage ./packages/bat-gherkin-syntax { inherit sources; };
            }
            // prev.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-darwin") {
              cmux = final.callPackage ./packages/cmux { inherit sources; };
            };
            tmuxPlugins = prev.tmuxPlugins // {
              tmux-open-nvim = final.callPackage ./packages/tmux-open-nvim { inherit sources; };
              tmux-mouse-swipe = final.callPackage ./packages/tmux-mouse-swipe { inherit sources; };
              tmux-nerd-font-window-name = final.callPackage ./packages/tmux-nerd-font-window-name {
                inherit sources;
              };
            };
            yaziPlugins =
              prev.yaziPlugins
              // (
                let
                  ours = final.callPackage ./packages/yaziPlugins { };
                in
                {
                  inherit (ours) icons-brew bunny;
                }
              );

            # TEMPORARY back-compat bridge for the A5 namespacing migration
            # (commit 1b17129 moved overlay packages under `phillipgreenii.*`).
            # Unmigrated consumers (nix-personal, agent-support) still reference
            # the old top-level names, so re-expose aliases to keep them building
            # until the consumer-side ADR-0047 migration lands. Remove then.
            # NOTE: c9watch was genuinely dropped (not just moved) and so cannot
            # be aliased here — it is disabled at the consumer instead.
            inherit (final.phillipgreenii) beads-web bat-gherkin-syntax;
          }
          // prev.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-darwin") {
            # cmux only exists under phillipgreenii.* on aarch64-darwin (see above).
            inherit (final.phillipgreenii) cmux;
          };
      };
    };
}

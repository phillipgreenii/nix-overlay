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

          # devshell.extraInputs — see nix-repo-base/flake-modules/devshell.nix:7.
          # nvfetcher's generated _sources/ tree is excluded from lint+format by the
          # producer default (tc-uergy), so no per-repo overrides are needed here.
          phillipgreenii.devshell.extraInputs = with pkgs; [
            jq
            curl
            gnused
            nvfetcher
          ];

          # Build every package as a check. Use config.packages (same-perSystem
          # scope) rather than self.packages.${system} which forces an eval
          # cycle through flake-parts' mkPerSystemFile.
          #
          # Also surface package passthru.tests as checks so `nix flake check`
          # exercises the CLI smoke tests (tc-cyvj8): a successful build only
          # proves the derivation realised, not that its binary runs.
          # `beads-web-version` runs `beads-web --version`. beads-web is only in
          # config.packages on its supported systems (see the platform-gated
          # `packages` below), so the `? beads-web` guard keeps this test off
          # beads-web's unsupported systems.
          checks =
            config.packages
            // pkgs.lib.optionalAttrs (config.packages ? beads-web) {
              beads-web-version = config.packages.beads-web.passthru.tests.version;
            };

          packages =
            let
              extended = pkgs.extend self.overlays.default;
            in
            {
              inherit (extended.phillipgreenii)
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
            # beads-web ships prebuilt release binaries only for these systems.
            # Expose it (and thereby make it a flake check) only there, so
            # `nix flake check --all-systems` does not force its drv on an
            # unsupported host and trip meta.platforms' "not available on this
            # platform" guard (tc-hgn29). Reading meta.platforms does not force
            # the drv, so this predicate is eval-safe on every system.
            //
              pkgs.lib.optionalAttrs
                (pkgs.lib.elem pkgs.stdenv.hostPlatform.system extended.phillipgreenii.beads-web.meta.platforms)
                {
                  inherit (extended.phillipgreenii) beads-web;
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

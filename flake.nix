{
  description = "Third-party Nix packages absent from or outdated in nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    phillipgreenii-nix-base = {
      url = "github:phillipgreenii/nix-repo-base";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
        treefmt-nix.follows = "treefmt-nix";
        git-hooks.follows = "git-hooks";
      };
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      phillipgreenii-nix-base,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;
        treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
        checks-lib = phillipgreenii-nix-base.lib.mkChecks pkgs;
        pre-commit = phillipgreenii-nix-base.lib.mkPreCommitHooks {
          inherit system;
          src = ./.;
          treefmtWrapper = treefmtEval.config.build.wrapper;
        };
        yaziPluginSet = pkgs.callPackage ./packages/yaziPlugins { };
      in
      {
        formatter = treefmtEval.config.build.wrapper;

        checks = {
          formatting = treefmtEval.config.build.check self;
          linting = checks-lib.linting ./.;
        }
        # Build every package in self.packages.${system} so CI exercises the
        # derivations, not just lint/format.
        # NOTE: if a future package name collides with "formatting" or
        # "linting", it will silently shadow the check.
        // self.packages.${system};

        devShells.default = phillipgreenii-nix-base.lib.mkDevShell {
          inherit pkgs;
          pre-commit-shellHook = pre-commit.shellHook;
          extraInputs = [
            pkgs.jq
            pkgs.curl
            pkgs.gnused
          ];
        };

        packages =
          let
            extended = pkgs.extend self.overlays.default;
          in
          {
            inherit (extended)
              beads-web
              bat-gherkin-syntax
              gascity
              ;
            inherit (extended.tmuxPlugins)
              tmux-open-nvim
              tmux-mouse-swipe
              tmux-nerd-font-window-name
              ;
            yaziPlugins-icons-brew = extended.yaziPlugins.icons-brew;
            yaziPlugins-bunny = extended.yaziPlugins.bunny;

            fix-lint = pkgs.writeShellScriptBin "fix-lint" ''
              exec ${lib.getExe pkgs.statix} fix "''${@:-.}"
            '';

            install-pre-commit-hooks = pkgs.writeShellScriptBin "install-pre-commit-hooks" ''
              ${pre-commit.shellHook}
              echo "Pre-commit hooks installed successfully!"
              echo "Run 'pre-commit run --all-files' to test them."
            '';
          }
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            inherit (extended) cmux;
          };

        legacyPackages = {
          yaziPlugins = {
            inherit (yaziPluginSet) icons-brew bunny;
          };
        };

        apps =
          let
            mkApp = drv: {
              type = "app";
              program = "${drv}/bin/${drv.meta.mainProgram or drv.name}";
            };
          in
          {
            update-cmux = mkApp (pkgs.callPackage ./nix/update-cmux.nix { });
            update-beads-web = mkApp (pkgs.callPackage ./nix/update-beads-web.nix { });
            update-gascity = mkApp (pkgs.callPackage ./nix/update-gascity.nix { });
          };
      }
    )
    // {
      homeModules.install-metadata = phillipgreenii-nix-base.lib.mkInstallMetadata {
        flakeSelf = self;
        name = "phillipgreenii-nix-overlay";
      };

      overlays.firefox-binary-wrapper = import ./overlays/firefox-binary-wrapper.nix;

      overlays.default =
        final: prev:
        {
          beads-web = final.callPackage ./packages/beads-web { };
          bat-gherkin-syntax = final.callPackage ./packages/bat-gherkin-syntax { };
          gascity = final.callPackage ./packages/gascity { };
          tmuxPlugins = prev.tmuxPlugins // {
            tmux-open-nvim = final.callPackage ./packages/tmux-open-nvim { };
            tmux-mouse-swipe = final.callPackage ./packages/tmux-mouse-swipe { };
            tmux-nerd-font-window-name = final.callPackage ./packages/tmux-nerd-font-window-name { };
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
        }
        // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
          cmux = final.callPackage ./packages/cmux { };
        };
    };
}

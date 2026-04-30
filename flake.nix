{
  description = "Third-party Nix packages absent from or outdated in nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
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
      in
      {
        formatter = treefmtEval.config.build.wrapper;

        checks = {
          formatting = treefmtEval.config.build.check self;
          linting = checks-lib.linting ./.;
        };

        devShells.default = phillipgreenii-nix-base.lib.mkDevShell {
          inherit pkgs;
          pre-commit-shellHook = pre-commit.shellHook;
        };

        packages = {
          beads-web = pkgs.callPackage ./packages/beads-web { };
          tmux-open-nvim = pkgs.callPackage ./packages/tmux-open-nvim { };
          tmux-mouse-swipe = pkgs.callPackage ./packages/tmux-mouse-swipe { };
          tmux-nerd-font-window-name = pkgs.callPackage ./packages/tmux-nerd-font-window-name { };
          bat-gherkin-syntax = pkgs.callPackage ./packages/bat-gherkin-syntax { };

          fix-lint = pkgs.writeShellScriptBin "fix-lint" ''
            ${lib.getExe pkgs.statix} fix ${./.}
          '';

          install-pre-commit-hooks = pkgs.writeShellScriptBin "install-pre-commit-hooks" ''
            ${pre-commit.shellHook}
            echo "Pre-commit hooks installed successfully!"
            echo "Run 'pre-commit run --all-files' to test them."
          '';
        }
        // lib.optionalAttrs pkgs.stdenv.isDarwin {
          cmux = pkgs.callPackage ./packages/cmux { };
          c9watch-gui = pkgs.callPackage ./packages/c9watch/gui.nix { };
          c9watch-cli = pkgs.callPackage ./packages/c9watch/cli.nix { };
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
            update-c9watch = mkApp (pkgs.callPackage ./nix/update-c9watch.nix { });
            update-beads-web = mkApp (pkgs.callPackage ./nix/update-beads-web.nix { });
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
        _final: prev:
        let
          ownPackages = self.packages.${prev.stdenv.hostPlatform.system};
        in
        {
          inherit (ownPackages) beads-web bat-gherkin-syntax;
          tmuxPlugins = prev.tmuxPlugins // {
            inherit (ownPackages)
              tmux-open-nvim
              tmux-mouse-swipe
              tmux-nerd-font-window-name
              ;
          };
        }
        // prev.lib.optionalAttrs prev.stdenv.isDarwin {
          inherit (ownPackages) cmux c9watch-gui c9watch-cli;
        };
    };
}

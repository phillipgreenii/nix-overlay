{
  description = "Third-party Nix packages absent from or outdated in nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;
        treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
      in
      {
        formatter = treefmtEval.config.build.wrapper;

        packages = {
          beads-web = pkgs.callPackage ./packages/beads-web { };
          tmux-open-nvim = pkgs.callPackage ./packages/tmux-open-nvim { };
          tmux-mouse-swipe = pkgs.callPackage ./packages/tmux-mouse-swipe { };
          tmux-nerd-font-window-name = pkgs.callPackage ./packages/tmux-nerd-font-window-name { };
          bat-gherkin-syntax = pkgs.callPackage ./packages/bat-gherkin-syntax { };
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
      overlays.default =
        final: prev:
        {
          beads-web = self.packages.${final.stdenv.hostPlatform.system}.beads-web;
          bat-gherkin-syntax = self.packages.${final.stdenv.hostPlatform.system}.bat-gherkin-syntax;
          tmuxPlugins = prev.tmuxPlugins // {
            tmux-open-nvim = self.packages.${final.stdenv.hostPlatform.system}.tmux-open-nvim;
            tmux-mouse-swipe = self.packages.${final.stdenv.hostPlatform.system}.tmux-mouse-swipe;
            tmux-nerd-font-window-name =
              self.packages.${final.stdenv.hostPlatform.system}.tmux-nerd-font-window-name;
          };
        }
        // final.lib.optionalAttrs final.stdenv.isDarwin {
          cmux = self.packages.${final.stdenv.hostPlatform.system}.cmux;
          c9watch-gui = self.packages.${final.stdenv.hostPlatform.system}.c9watch-gui;
          c9watch-cli = self.packages.${final.stdenv.hostPlatform.system}.c9watch-cli;
        };
    };
}

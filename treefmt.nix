{ pkgs, ... }:
{
  projectRootFile = "flake.nix";
  programs = {
    nixfmt = {
      enable = true;
      package = pkgs.nixfmt;
    };
    shellcheck.enable = true;
    shfmt.enable = true;
  };
}

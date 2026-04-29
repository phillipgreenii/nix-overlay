{ pkgs, ... }:
{
  projectRootFile = "flake.nix";
  programs = {
    nixfmt = {
      enable = true;
      package = pkgs.nixfmt-rfc-style;
    };
    shellcheck.enable = true;
    shfmt.enable = true;
  };
}

{ pkgs }:

pkgs.writeShellApplication {
  name = "update-beads-web";

  runtimeInputs = [
    pkgs.curl
    pkgs.jq
    pkgs.gnused
    pkgs.nix
  ];

  text = builtins.readFile ./update-beads-web.sh;
}

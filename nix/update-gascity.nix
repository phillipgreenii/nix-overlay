{ pkgs }:

pkgs.writeShellApplication {
  name = "update-gascity";

  runtimeInputs = [
    pkgs.curl
    pkgs.jq
    pkgs.gnused
    pkgs.nix
  ];

  text = builtins.readFile ./update-gascity.sh;
}

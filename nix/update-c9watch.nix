{ pkgs }:

pkgs.writeShellApplication {
  name = "update-c9watch";

  runtimeInputs = [
    pkgs.curl
    pkgs.jq
    pkgs.gnused
    pkgs.nix
  ];

  text = builtins.readFile ./update-c9watch.sh;
}

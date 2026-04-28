{ pkgs }:

pkgs.writeShellApplication {
  name = "update-cmux";

  runtimeInputs = [
    pkgs.curl
    pkgs.jq
    pkgs.gnused
    pkgs.nix
  ];

  text = builtins.readFile ./update-cmux.sh;
}

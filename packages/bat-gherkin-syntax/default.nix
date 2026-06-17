{ lib, pkgs }:
# last updated: unstable-2024-10-12
pkgs.fetchFromGitHub {
  owner = "keith-hall";
  repo = "SublimeGherkinSyntax";
  rev = "ec3fae90209136a89a5027f61167e04790c83382";
  sha256 = "sha256-yYIMfzAiKdQsl3OPSevENsrs4TkNe+eVVPSRbtHagNY=";
  meta = {
    platforms = lib.platforms.unix;
  };
}

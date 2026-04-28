{ pkgs }:
# last updated: unstable-2024-10-12
pkgs.fetchFromGitHub {
  owner = "keith-hall";
  repo = "SublimeGherkinSyntax";
  rev = "master";
  sha256 = "sha256-yYIMfzAiKdQsl3OPSevENsrs4TkNe+eVVPSRbtHagNY=";
}

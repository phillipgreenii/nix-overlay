{
  lib,
  fetchFromGitHub,
  mkYaziPlugin,
}:
mkYaziPlugin {
  pname = "bunny.yazi";
  version = "unstable-2026-03-09";

  src = fetchFromGitHub {
    owner = "stelcodes";
    repo = "bunny.yazi";
    rev = "71b14a3d624572f4884354c2e218296e9ece07cc";
    hash = "sha256-uQO0C00yOFPWq8KEO/kEZM6tFZRc9SiXfgN7kzlwDeA=";
  };

  meta = {
    description = "Yazi quick-jump plugin";
    homepage = "https://github.com/stelcodes/bunny.yazi";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}

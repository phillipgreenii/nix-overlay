{
  lib,
  fetchFromGitHub,
  mkYaziPlugin,
}:
mkYaziPlugin {
  pname = "icons-brew.yazi";
  version = "unstable-2026-02-22";

  src = fetchFromGitHub {
    owner = "lpnh";
    repo = "icons-brew.yazi";
    rev = "61fddf8d02bd6f4af15b2c93e5ce1c6affe55d17";
    hash = "sha256-hLYQ0ni8GhUPOHka0ydp4pBg0a/VaxYl6QPiK37IO9I=";
  };

  meta = {
    description = "Yazi plugin for per-extension brew (Nerd Font) icons";
    homepage = "https://github.com/lpnh/icons-brew.yazi";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}

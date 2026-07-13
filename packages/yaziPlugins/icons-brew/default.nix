{
  lib,
  mkYaziPlugin,
  sources,
}:
mkYaziPlugin {
  pname = "icons-brew.yazi";
  version = "unstable-${sources.icons-brew.date}";
  src = sources.icons-brew.src;

  meta = {
    description = "Yazi plugin for per-extension brew (Nerd Font) icons";
    homepage = "https://github.com/lpnh/icons-brew.yazi";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}

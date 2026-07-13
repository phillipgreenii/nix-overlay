{
  lib,
  mkYaziPlugin,
  sources,
}:
mkYaziPlugin {
  pname = "bunny.yazi";
  version = "unstable-${sources.bunny.date}";
  src = sources.bunny.src;

  meta = {
    description = "Yazi quick-jump plugin";
    homepage = "https://github.com/stelcodes/bunny.yazi";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}

{
  lib,
  stdenvNoCC,
  callPackage,
}:
let
  mkYaziPlugin =
    args@{
      meta ? { },
      installPhase ? null,
      ...
    }:
    stdenvNoCC.mkDerivation (
      args
      // {
        installPhase =
          if installPhase != null then
            installPhase
          else
            ''
              runHook preInstall

              cp -r . $out

              runHook postInstall
            '';
        meta = meta // {
          description = meta.description or "";
          platforms = meta.platforms or lib.platforms.all;
        };
      }
    );

  callPlugin = path: callPackage path { inherit mkYaziPlugin; };
in
{
  inherit mkYaziPlugin;
  icons-brew = callPlugin ./icons-brew;
  bunny = callPlugin ./bunny;
}

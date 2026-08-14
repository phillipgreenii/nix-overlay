{
  lib,
  buildGoModule,
  sources,
}:
buildGoModule rec {
  pname = "gomu";
  version = lib.removePrefix "v" sources.gomu.version;
  src = sources.gomu.src;

  vendorHash = "sha256-uBu5bMRUMX9v0v4P6EuL7ybQw1Nx2YOzhpcJm+A16rc=";

  subPackages = [ "cmd/gomu" ];

  # Load-bearing: without -X main.version the binary reports "gomu version dev"
  # and the pin is unattributable, defeating spec E1.
  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  doCheck = false;

  meta = {
    description = "Mutation testing engine for Go";
    homepage = "https://github.com/sivchari/gomu";
    license = lib.licenses.mit;
    mainProgram = "gomu";
    platforms = lib.platforms.unix;
  };
}

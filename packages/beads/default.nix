{
  lib,
  buildGoModule,
  makeWrapper,
  dolt,
  icu,
  pkg-config,
  sources,
  # Name stamped into `bd --version` after `nix:` so a build is identifiable at
  # runtime ("bd version 1.3.1 (nix:<buildIdentity>)") and distinguishable from
  # an unstamped upstream build ("... (dev)"). A consumer that wants its own
  # identity overrides this argument.
  buildIdentity ? "phillipgreenii-nix-overlay",
  # When true the bd wrapper also exports BEADS_DOLT_AUTO_START=0 so no bd
  # consumer (login shell, GUI app or daemon) transparently auto-starts a
  # competing dolt sql-server. Defaults true (fail-safe).
  forbidDoltAutoStart ? true,
}:
let
  # nvfetcher pins the release tag verbatim (`vX.Y.Z`); strip it for the
  # user-facing version.
  version = lib.removePrefix "v" sources.beads.version;
in
buildGoModule {
  pname = "beads";
  inherit version;
  src = sources.beads.src;

  # Re-hash when the nvfetcher pin moves (refresh-dependent-hashes.sh does it).
  vendorHash = "sha256-mnQo3S7JLrx0nY5EIP3qQVqWLTlisYhjJFzqgPD/xu8=";

  ldflags = [
    "-X main.Commit=${sources.beads.src.rev}"
    "-X main.Build=nix:${buildIdentity}"
  ];

  nativeBuildInputs = [
    makeWrapper
    pkg-config
  ];

  buildInputs = [ icu ];

  # go-icu-regex's cgo directives use raw -licui18n etc. with no
  # `#cgo pkg-config:` line, so pkg-config never runs; pass the icu include and
  # library dirs explicitly so the build does not depend on which cc cgo
  # resolves.
  env = {
    CGO_ENABLED = "1";
    CGO_CFLAGS = "-I${lib.getDev icu}/include";
    CGO_CXXFLAGS = "-I${lib.getDev icu}/include";
    CGO_LDFLAGS = "-L${lib.getLib icu}/lib";
  };

  subPackages = [ "cmd/bd" ];

  doCheck = false;

  # Wrapper:
  #  - dolt on PATH, so bd uses the pinned dolt rather than whatever the caller
  #    has.
  #  - BD_BACKUP_ENABLED=0: bd auto-provisions and syncs a Dolt "backup_export"
  #    remote under <cwd>/.beads/backup whenever backup.enabled has only its
  #    default source and a git remote exists. Baking the variable into the
  #    wrapper (rather than a login-shell profile) makes it reach every bd
  #    invocation, including launchd daemons and `env -i` activation. `--set`,
  #    not `--set-default`, hard-forces it off.
  #  - BEADS_DOLT_AUTO_START=0 (forbidDoltAutoStart): see the argument.
  postInstall = ''
    wrapProgram $out/bin/bd \
      --prefix PATH : ${lib.makeBinPath [ dolt ]} \
      --set BD_BACKUP_ENABLED 0 \
      ${lib.optionalString forbidDoltAutoStart "--set BEADS_DOLT_AUTO_START 0"}
  '';

  # The version smoke test (flake checks.beads-version) asserts `bd --version`
  # reports the package version, guarding the nvfetcher pin against drift.

  meta = {
    description = "Distributed issue tracker designed for AI-supervised coding workflows";
    homepage = "https://github.com/gastownhall/beads";
    changelog = "https://github.com/gastownhall/beads/releases/tag/${sources.beads.version}";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
    mainProgram = "bd";
    platforms = lib.platforms.unix;
  };
}

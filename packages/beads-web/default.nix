{
  lib,
  stdenv,
  autoPatchelfHook,
  openssl,
  zlib,
  testers,
  sources,
}:

let
  # Prebuilt upstream release binaries, keyed by Nix system. Off-platform,
  # `current` is null so the derivation still *evaluates* (src/version fall
  # back to null); meta.platforms below then drives Nix's standard "package
  # not available on this platform" gating instead of a hard eval-time throw
  # (tc-hgn29).
  srcs = {
    aarch64-darwin = sources.beads-web-darwin-arm64;
    x86_64-linux = sources.beads-web-linux-x64;
  };
  current = srcs.${stdenv.hostPlatform.system} or null;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "beads-web";
  version = if current != null then current.version else "unsupported";
  src = if current != null then current.src else null;

  dontUnpack = true;

  # The upstream linux release is a generic-linux, dynamically linked ELF
  # (needs libssl/libcrypto/libz/libgcc_s) that cannot run on NixOS as-is.
  # autoPatchelfHook rewrites the interpreter + RPATH so the binary — and the
  # passthru.tests.version smoke test below — actually runs. No-op on darwin.
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    (lib.getLib stdenv.cc.cc)
    openssl
    zlib
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 $src $out/bin/beads-web
    runHook postInstall
  '';

  # Smoke test: a successful build only proves the hash matched and the
  # derivation realised; running `beads-web --version` proves the binary is
  # correctly linked and actually executes (tc-cyvj8 / deepdive T3). Wired
  # into flake.nix `checks` so `nix flake check` exercises it.
  #
  # NOTE: cmux (packages/cmux) deliberately gets NO passthru.tests.version:
  # it is an Electron .dmg, aarch64-darwin only, and `cmux --version` requires
  # launching the .app bundle — not testable on this x86_64-linux CI host
  # (tc-cyvj8).
  passthru.tests.version = testers.testVersion {
    package = finalAttrs.finalPackage;
  };

  meta = with lib; {
    description = "Visual Kanban UI for Beads CLI — real-time sync, epic tracking, GitOps";
    homepage = "https://github.com/weselow/beads-web";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "beads-web";
    platforms = attrNames srcs;
  };
})

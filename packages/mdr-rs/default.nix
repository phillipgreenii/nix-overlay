{
  lib,
  stdenv,
  rustPlatform,
  pkg-config,
  wrapGAppsHook3,
  addDriverRunpath,
  gtk3,
  webkitgtk_4_1,
  libGL,
  libxkbcommon,
  xdotool,
  sources,
}:
let
  version = lib.removePrefix "v" sources.mdr-rs.version;
in
rustPlatform.buildRustPackage {
  pname = "mdr";
  inherit version;
  src = sources.mdr-rs.src;

  # Upstream did not commit a Cargo.lock at v0.3.2 (it was .gitignore'd, even
  # in the release tag tree). As of v0.5.1 upstream ships its own Cargo.lock,
  # so this is now just a copy of sources.mdr-rs.src's own Cargo.lock rather
  # than one generated independently by us. Regenerate it whenever this
  # package's pinned version bumps and the build starts failing with a
  # Cargo.lock mismatch: `cp <fetched source>/Cargo.lock ./Cargo.lock`. Unlike
  # gomu/pint/glowm's mechanical vendorHash bump, this step can't be automated
  # by the nightly update-locks.sh run -- a dependency-changing version bump
  # surfaces as a failing CI check on the auto-opened PR instead of silently
  # going stale, which is the intended fallback.
  #
  # If upstream ever again ships a tag with NO Cargo.lock, cargoSetupPostPatchHook
  # will fail with "Missing Cargo.lock from src... Hint: You can use the
  # cargoPatches attribute to add a Cargo.lock manually to the build" --
  # that's nixpkgs' own documented workaround; re-add a cargoPatches entry
  # that creates the file from /dev/null at that point, not before (a patch
  # that CREATES a file fails outright if the file already exists, which is
  # exactly what broke when upstream started shipping its own lock).
  #
  # The lock resolves every target's dependency graph, not just the host's
  # (cargo does not prune by target), so the Darwin-generated lock already
  # carries the Linux-only gtk/webkit2gtk/libxdo crates -- verified present
  # by name in ./Cargo.lock.
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [
    pkg-config
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    # The GTK/WebKitGTK webview backend needs its GSettings schemas and
    # GDK_PIXBUF module path baked into the binary's environment, same as
    # upstream's own flake.nix. The hook is spelled wrapGAppsHook3 here:
    # upstream's `wrapGAppsHook` no longer resolves at this repo's pinned
    # nixpkgs rev -- it throws "'wrapGAppsHook' has been renamed to/replaced
    # by 'wrapGAppsHook3'" (verified by eval).
    wrapGAppsHook3

    # Setup hook providing the `addDriverRunpath` shell function used in
    # postFixup below to wire the GL/EGL driver runpath for the egui/webview
    # backends (see buildInputs comment and postFixup for the full story).
    addDriverRunpath
  ];

  # Darwin needs no buildInputs: `darwin.apple_sdk` was removed from nixpkgs
  # (throws in this repo's pinned nixpkgs-26.05-darwin); nixpkgs' own
  # migration guidance is to drop such references outright, since the
  # default SDK already provides WebKit/AppKit/CoreServices for the
  # webview/egui backends.
  #
  # Linux mirrors upstream's flake.nix buildInputs with ONE substitution:
  # upstream lists `libxdo`, which does not exist as an attribute at this
  # repo's pinned nixpkgs rev. nixpkgs ships that library inside `xdotool`
  # -- verified: the xdotool output carries lib/libxdo.so,
  # lib/pkgconfig/libxdo.pc and include/xdo.h, which is what the
  # libxdo-sys crate's pkg-config probe resolves against.
  #
  # Scope on Linux: this is the BUILD dependency set (upstream's), and all
  # three backends compile -- `mdr --list-backends` reports egui, webview and
  # tui all `[compiled]`, and `ldd` resolves every linked library including
  # libxdo.so.3. The two GRAPHICAL backends additionally dlopen libEGL.so.1
  # and libxkbcommon.so.0 / libxkbcommon-x11.so.0 at RUN time -- none of
  # those are DT_NEEDED at link time (dlopen, not link), so they never show
  # up in `ldd` and plain buildInputs membership does not put them in the
  # runpath (nix's RPATH-shrinking in fixup strips any store path that isn't
  # actually referenced by a DT_NEEDED entry). Wired up in postFixup below:
  # addDriverRunpath for the GL/EGL driver, an LD_LIBRARY_PATH wrap for
  # libxkbcommon. This is documentation, not a claim it's been display-tested
  # -- this sandbox has no display, so `mdr --backend egui/webview <file>`
  # actually opening a window still needs verifying on a machine that has
  # one; only the wiring itself (paths resolve to real store paths / a real
  # runtime search path) has been confirmed here.
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    gtk3
    webkitgtk_4_1
    libGL
    xdotool
  ];

  # wrapGAppsHook3 (nativeBuildInputs, Linux only) would otherwise wrap
  # $out/bin/mdr itself: it renames the real ELF binary to
  # $out/bin/.mdr-wrapped and replaces $out/bin/mdr with a wrapper script,
  # which would leave nothing left for addDriverRunpath below to patchelf
  # (isELF check on a shell script is a silent no-op) short of chasing the
  # renamed path. Deferring to a single manual wrapProgram call in postFixup
  # -- using gappsWrapperArgs, which wrapGAppsHook3's setup hook still
  # populates with the GSettings/GDK_PIXBUF/XDG_DATA_DIRS entries regardless
  # of dontWrapGApps -- keeps that GTK/webview wiring intact while adding our
  # own args in the same wrap. Same pattern nixpkgs' own mission-center
  # package uses to combine wrapGAppsHook-style wrapping with
  # addDriverRunpath.
  dontWrapGApps = true;

  postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    # libEGL.so.1 is hardware/driver-specific, same as every other
    # addDriverRunpath consumer in nixpkgs: set DT_RUNPATH to
    # /run/opengl-driver(-32)/lib on the real ELF binary so a bare
    # dlopen("libEGL.so.1") resolves against whatever GL driver the target
    # NixOS machine has installed. Must run in postFixup (RUNPATH-shrinking
    # earlier in fixup would strip it right back out -- see
    # addDriverRunpath's own setup-hook comment) and must run before
    # wrapProgram below renames the binary out from under $out/bin/mdr.
    addDriverRunpath "$out/bin/mdr"

    # libxkbcommon.so.0 / libxkbcommon-x11.so.0 are plain nix store
    # libraries, not driver-specific, so an LD_LIBRARY_PATH wrap (rather
    # than a runpath patch) is the right mechanism -- and the one
    # documented above. A single pkgs.libxkbcommon output provides both
    # sonames (its pkgConfigModules list both "xkbcommon" and
    # "xkbcommon-x11").
    wrapProgram "$out/bin/mdr" \
      "''${gappsWrapperArgs[@]}" \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ libxkbcommon ]}
  '';

  # Skip upstream's test suite: the default feature set builds a GUI/webview
  # toolkit whose tests expect a display; the nvfetcher-pinned SHA plus the
  # committed Cargo.lock are the integrity proof, same rationale as
  # pint/glowm/gomu's doCheck = false.
  doCheck = false;

  meta = {
    description = "A lightweight Markdown viewer with Mermaid diagram support and live reload";
    homepage = "https://github.com/CleverCloud/mdr";
    license = lib.licenses.mit;
    mainProgram = "mdr";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}

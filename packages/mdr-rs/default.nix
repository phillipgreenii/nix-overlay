{
  lib,
  stdenv,
  rustPlatform,
  pkg-config,
  wrapGAppsHook3,
  gtk3,
  webkitgtk_4_1,
  libGL,
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
  # and libxkbcommon.so.0 at RUN time; those are deliberately not wired into
  # the runpath here, because the consumer that needs this on Linux
  # (monorepod, headless) uses the tui backend. Wiring them up
  # (addDriverRunpath + an LD_LIBRARY_PATH wrap) belongs with the first
  # machine that actually runs mdr's GUI on Linux and can test it against a
  # display.
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    gtk3
    webkitgtk_4_1
    libGL
    xdotool
  ];

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

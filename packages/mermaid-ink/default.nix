{
  lib,
  stdenvNoCC,
  nodejs_24,
  pnpm_11,
  fetchPnpmDeps,
  pnpmConfigHook,
  makeWrapper,
  playwright-driver,
  sources,
}:
let
  # The headless Chromium that Puppeteer drives. Puppeteer's own download is
  # skipped (pnpmConfigHook installs with --ignore-scripts), and nixpkgs has no
  # Chromium for darwin, so use Playwright's chromium-headless-shell: a
  # fixed-output fetch of the pinned build (cacheable, available on darwin and
  # linux) rather than a browser installed outside nix. Resolved to its
  # platform-specific executable at build time.
  chromiumHeadlessShell = playwright-driver.components.chromium-headless-shell;
in
# Local, mermaid.ink-compatible renderer (operator ruling 2026-10-06, bead
# pg2-aq0t7, IT-audit item C.7). This is upstream jihchi/mermaid.ink itself:
# the same `/img/<state>?type=png` and `/svg/<state>` routes that
# mermaid-live-editor builds its image-export URLs from (its `rendererUrl`
# contract, src/lib/util/state.svelte.ts), so pointing the editor's
# `rendererUrl` at this service keeps image export working with no diagram text
# leaving the machine. It renders in a headless browser against a mermaid copy
# vendored in its own node_modules (src/static/mermaid.html loads it from
# disk), so a render makes no network request.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "mermaid-ink";
  # Upstream's package.json version is not bumped per commit; nvfetcher tracks
  # the default branch head, so the version is the commit date.
  version = "0-unstable-${sources.mermaid-ink.date}";
  src = sources.mermaid-ink.src;

  # Runtime dependencies only; dev tooling (vitest, sharp, prettier, ...) is
  # not needed to serve.
  pnpmInstallFlags = [ "--prod" ];

  # Hardcoded fixed-output hash of the pnpm store; same refresh procedure and
  # same reasoning as packages/mermaid-live-editor (NOT refreshed by the
  # nightly update-locks.sh, so a bump that changes pnpm-lock.yaml surfaces as
  # a failing check): set `hash` to lib.fakeHash, run
  # `nix build .#mermaid-ink`, paste the "got:" hash. pnpm_11 because
  # nixpkgs flags the older pnpm majors as insecure; upstream's lockfile
  # (lockfileVersion 9.0) is read by pnpm 11.
  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs)
      pname
      version
      src
      pnpmInstallFlags
      ;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    hash = "sha256-9RJv/hISXLDiCL7RQ0QyMGD4ojBkIt9lcrt5Y4X1srk=";
  };

  nativeBuildInputs = [
    nodejs_24
    pnpm_11
    pnpmConfigHook
    makeWrapper
  ];

  env.PUPPETEER_SKIP_DOWNLOAD = "1";

  # Upstream's `app.listen(PORT)` binds every interface, which would expose an
  # unauthenticated headless-browser renderer to the LAN. Bind a HOST that
  # defaults to loopback instead; --replace-fail so an upstream change to this
  # line fails the build rather than silently reverting to all-interfaces.
  postPatch = ''
    substituteInPlace src/index.js \
      --replace-fail "app.listen(PORT);" "app.listen(PORT, process.env.HOST || '127.0.0.1');"
  '';

  dontBuild = true;

  # src/static/mermaid.mjs imports `../../node_modules/...`, so src/ and
  # node_modules/ must stay siblings. cp -a keeps pnpm's relative symlinks.
  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/mermaid-ink" "$out/bin"
    cp -a src node_modules package.json "$out/lib/mermaid-ink/"

    shell=$(find ${chromiumHeadlessShell} -maxdepth 2 -name chrome-headless-shell -type f | head -n1)
    test -x "$shell" || { echo "chrome-headless-shell not found in ${chromiumHeadlessShell}" >&2; exit 1; }

    # Env defaults (--set-default, so the service module can override):
    #   HOST/PORT              loopback only; 38474 sits next to the editor's 38473
    #   PUPPETEER_EXECUTABLE_PATH / HEADLESS_MODE   the nix-provided browser
    #   FONT_AWESOME_CSS_URL   svg.js otherwise injects an @import of
    #                          cdnjs.cloudflare.com into every SVG it returns
    #                          (fetched by whoever opens that SVG standalone); an
    #                          empty data: URL keeps the output free of any
    #                          third-party URL. Raster (PNG) output is unaffected;
    #                          standalone SVGs lose only the icon-font CSS.
    #   QUEUE_ADD_TIMEOUT      upstream's 3s is tight on a loaded machine
    makeWrapper ${lib.getExe nodejs_24} "$out/bin/mermaid-ink" \
      --add-flags "$out/lib/mermaid-ink/src/index.js" \
      --chdir "$out/lib/mermaid-ink" \
      --set-default HOST 127.0.0.1 \
      --set-default PORT 38474 \
      --set-default PUPPETEER_EXECUTABLE_PATH "$shell" \
      --set-default HEADLESS_MODE shell \
      --set-default FONT_AWESOME_CSS_URL "data:text/css;charset=utf-8," \
      --set-default QUEUE_ADD_TIMEOUT 30000

    runHook postInstall
  '';

  meta = {
    description = "mermaid.ink render service (img/svg/pdf) run as a local loopback service with a nix-provided headless Chromium";
    homepage = "https://github.com/jihchi/mermaid.ink";
    license = lib.licenses.mit;
    mainProgram = "mermaid-ink";
    platforms = lib.platforms.all;
  };
})

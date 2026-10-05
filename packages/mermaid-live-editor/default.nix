{
  lib,
  stdenvNoCC,
  nodejs_24,
  pnpm_11,
  fetchPnpmDeps,
  pnpmConfigHook,
  sources,
  # Build-time env baked into the bundle (vite envPrefix 'MERMAID_', read via
  # import.meta.env in src/lib/util/env.ts). Defaults here are the PRIVACY
  # build: upstream's .env points at kroki.io, enables mermaid.ai links, and
  # its published image bakes those defaults, hence our own build. Override via
  # `.override { krokiRendererUrl = "..."; }`.
  #
  # rendererUrl is deliberately KEPT at mermaid.ink (operator ruling
  # 2026-10-01: wants image export). Diagram text is sent to that host whenever
  # an image URL is fetched.
  rendererUrl ? "https://mermaid.ink",
  krokiRendererUrl ? "",
  analyticsUrl ? "",
  enableMermaidChartLinks ? false,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "mermaid-live-editor";
  # Upstream publishes no tags/releases; nvfetcher tracks the `develop` branch
  # head, so the version is the commit date.
  version = "0-unstable-${sources.mermaid-live-editor.date}";
  src = sources.mermaid-live-editor.src;

  # Hardcoded fixed-output hash of the pnpm store. NOT refreshed by the nightly
  # update-locks.sh (verified: neither it nor nix-repo-base's
  # update-locks-lib.bash has a step for it, same as mdr-rs's Cargo.lock): a
  # bump that changes pnpm-lock.yaml surfaces as a failing CI check on the
  # auto-opened PR instead of silently going stale. To refresh: set `hash` to
  # lib.fakeHash, run `nix build .#mermaid-live-editor`, and paste the
  # "got:" hash from the mismatch error.
  #
  # pnpm is pnpm_11 because nixpkgs flags pnpm_8/9/10 as insecure (known CVEs,
  # 2026-10-05); it is only a build-time tool here. Upstream's lockfile is
  # lockfileVersion 9.0, which pnpm 11 reads. The pnpm used by fetchPnpmDeps is
  # part of the fixed-output hash, so changing it means refreshing `hash`.
  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    hash = "sha256-8PWEYJPjE5IblG5P+6uGNXyg8eQzKl+XntW5NM8OV7s=";
  };

  nativeBuildInputs = [
    nodejs_24
    pnpm_11
    pnpmConfigHook
  ];

  # pnpmConfigHook installs with --ignore-scripts, so upstream's postinstall
  # (`husky install && svelte-kit sync && git config ...`) never runs; `vite
  # build` needs .svelte-kit/tsconfig.json, so run the sync step explicitly.
  env = {
    MERMAID_RENDERER_URL = rendererUrl;
    MERMAID_KROKI_RENDERER_URL = krokiRendererUrl;
    MERMAID_ANALYTICS_URL = analyticsUrl;
    MERMAID_IS_ENABLED_MERMAID_CHART_LINKS = lib.boolToString enableMermaidChartLinks;
  };

  buildPhase = ''
    runHook preBuild

    pnpm exec svelte-kit sync
    pnpm run build

    runHook postBuild
  '';

  # adapter-static writes to docs/ (svelte.config.js: pages 'docs').
  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share"
    cp -r docs "$out/share/mermaid-live-editor"

    runHook postInstall
  '';

  meta = {
    description = "Mermaid Live Editor static site, built with Kroki, mermaid.ai links and analytics disabled";
    homepage = "https://github.com/mermaid-js/mermaid-live-editor";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})

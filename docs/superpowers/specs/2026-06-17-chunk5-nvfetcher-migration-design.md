# Chunk 5: nvfetcher Migration — Design

**Date:** 2026-06-17
**Source review:** [`2026-06-12-nix-overlay-deepdive.md`](../../../2026-06-12-nix-overlay-deepdive.md)
**Findings addressed:** M1 (nvfetcher adoption — replaces ~400 lines of bespoke updater shell), A3 (four near-identical updater scripts + two near-identical sed functions), B7 (comment-as-data and grep/sed-based Nix editing).
**Estimated effort:** ~3–4 hours implementation + CI cycle

## Goal

Replace the three bespoke updater scripts (`nix/update-{cmux,beads-web,gascity}.sh`) plus the two inline `update_tmux_plugin`/`update_bat_syntax` functions in `update-locks.sh` with a single `nvfetcher.toml` manifest plus committed `_sources/generated.nix`. Package files consume from a `sources` set instead of carrying inline hashes. `update-locks.sh` shrinks to one `ul_run_step "nvfetcher"` call (plus the existing `nix-flake-update` step). Net: ~400 lines of shell deleted, the sed/grep fragility class (B7) eliminated, and every source pinning lives in one declarative manifest.

## Non-Goals

- **S3/M6 provenance verification** (`gh attestation verify`, goreleaser `checksums.txt` cross-check) — deferred to a future security-focused chunk.
- **Switching tmux plugins / bat-gherkin away from `unstable-<date>` versioning convention** — keep the convention; the package files can format the version string from the resolved git rev/date.
- **yaziPlugins** — those are in-repo paths, not external sources. Out of scope.
- **Changing the per-system pkgs derivation, the overlay inversion (Chunk 2), the c9watch removal (Chunk 3), or the branch protection (Chunk 1).**
- **Reverting Chunk 4 U4 (`.pre-commit-config.yaml` gitignore)** — orthogonal.

## Workflow

One local branch `feat/nvfetcher` off `main`. Push to `origin` for human-merge. No PR opened. CI workflow only triggers on push-to-main / PR-against-main — verification is local via `nix flake check` (without `--no-build` — Chunk 3 lesson — to catch statix issues) and per-package `nix build`. CI runs on the merge to main.

Work in the worktree at `/home/tcadmin/workspace/nix-overlay-chunk1`. Branch directly off `origin/main`.

## Sources to migrate

| nvfetcher entry | Type | Tracks | Fetches |
|---|---|---|---|
| `beads-web-darwin-arm64` | github_tag + url | weselow/beads-web (latest tag) | `beads-web-darwin-arm64` asset |
| `beads-web-linux-x64` | github_tag + url | weselow/beads-web (latest tag) | `beads-web-linux-x64` asset |
| `gascity-darwin-arm64` | github_tag + url | gastownhall/gascity (latest tag) | `gascity_${ver}_darwin_arm64.tar.gz` |
| `gascity-linux-amd64` | github_tag + url | gastownhall/gascity (latest tag) | `gascity_${ver}_linux_amd64.tar.gz` |
| `cmux` | github_tag + url | manaflow-ai/cmux (latest tag) | `cmux-macos.dmg` |
| `tmux-open-nvim` | git branch tip | trevarj/tmux-open-nvim (master) | fetchFromGitHub at resolved rev |
| `tmux-mouse-swipe` | git branch tip | jaclu/tmux-mouse-swipe (main) | fetchFromGitHub at resolved rev |
| `tmux-nerd-font-window-name` | git branch tip | joshmedeski/tmux-nerd-font-window-name (main) | fetchFromGitHub at resolved rev |
| `bat-gherkin-syntax` | git branch tip | keith-hall/SublimeGherkinSyntax (master) | fetchFromGitHub at resolved rev |

That's 9 entries (4 multi-arch binaries split into 2 each + 5 single-source). The multi-arch packages (beads-web, gascity) each get one entry per supported platform — nvfetcher's URL templating uses `$ver` from src's detected version, so per-platform asset URLs need their own entries.

Note on `src.github_tag` vs `src.github`: `src.github` tracks the latest GitHub *release* (the Releases API), `src.github_tag` tracks the maximum tag (the Git tags API). For these projects the two normally agree, but tag-based tracking is the convention used across nvfetcher real-world configs (see iynaix/dotfiles). We pair it with `src.prefix = "v"` so `$ver` is the bare semver (e.g. `0.11.2`), matching the `v$ver` form in the existing release URLs.

## `nvfetcher.toml`

```toml
[beads-web-darwin-arm64]
src.github_tag = "weselow/beads-web"
src.prefix = "v"
fetch.url = "https://github.com/weselow/beads-web/releases/download/v$ver/beads-web-darwin-arm64"

[beads-web-linux-x64]
src.github_tag = "weselow/beads-web"
src.prefix = "v"
fetch.url = "https://github.com/weselow/beads-web/releases/download/v$ver/beads-web-linux-x64"

[gascity-darwin-arm64]
src.github_tag = "gastownhall/gascity"
src.prefix = "v"
fetch.url = "https://github.com/gastownhall/gascity/releases/download/v$ver/gascity_$ver_darwin_arm64.tar.gz"

[gascity-linux-amd64]
src.github_tag = "gastownhall/gascity"
src.prefix = "v"
fetch.url = "https://github.com/gastownhall/gascity/releases/download/v$ver/gascity_$ver_linux_amd64.tar.gz"

[cmux]
src.github_tag = "manaflow-ai/cmux"
src.prefix = "v"
fetch.url = "https://github.com/manaflow-ai/cmux/releases/download/v$ver/cmux-macos.dmg"

[tmux-open-nvim]
src.git = "https://github.com/trevarj/tmux-open-nvim"
src.branch = "master"
fetch.github = "trevarj/tmux-open-nvim"

[tmux-mouse-swipe]
src.git = "https://github.com/jaclu/tmux-mouse-swipe"
src.branch = "main"
fetch.github = "jaclu/tmux-mouse-swipe"

[tmux-nerd-font-window-name]
src.git = "https://github.com/joshmedeski/tmux-nerd-font-window-name"
src.branch = "main"
fetch.github = "joshmedeski/tmux-nerd-font-window-name"

[bat-gherkin-syntax]
src.git = "https://github.com/keith-hall/SublimeGherkinSyntax"
src.branch = "master"
fetch.github = "keith-hall/SublimeGherkinSyntax"
```

All URLs use the bare `$ver` form (no `${ver}`) — that is the documented substitution token. Multiple occurrences in a single URL work cleanly: see the iynaix/dotfiles `helium` entry (`helium-$ver-x86_64.AppImage` with a `v$ver` segment before it).

## `_sources/generated.nix` (committed; regenerated by `nvfetcher`)

After the implementer writes `nvfetcher.toml` and runs `nvfetcher` once, this file is produced and committed. Shape:

```nix
# This file was generated by nvfetcher, please do not modify it manually.
{
  fetchgit,
  fetchurl,
  fetchFromGitHub,
  dockerTools,
}:
{
  beads-web-darwin-arm64 = {
    pname = "beads-web-darwin-arm64";
    version = "0.11.2";
    src = fetchurl {
      url = "https://github.com/weselow/beads-web/releases/download/v0.11.2/beads-web-darwin-arm64";
      sha256 = "sha256-6+4ddKilgMHFfSBSNCQNPl2jZDmNtWpQ99zKn2bWnkc=";
    };
  };
  beads-web-linux-x64 = {
    pname = "beads-web-linux-x64";
    version = "0.11.2";
    src = fetchurl {
      url = "https://github.com/weselow/beads-web/releases/download/v0.11.2/beads-web-linux-x64";
      sha256 = "sha256-eDL5aAwQ41XK58YFirf7HLvImxR5PJeFr6WIzmS5IRE=";
    };
  };
  # ... binary entries above use fetchurl, no date field.
  # Git entries below (3 tmux plugins + bat-gherkin-syntax) use fetchFromGitHub
  # and include a `date` field formatted as YYYY-MM-DD (nvfetcher's git source
  # default; confirmed against real-world generated.nix from iynaix/dotfiles).
  tmux-open-nvim = {
    pname = "tmux-open-nvim";
    version = "<40-char-sha>";
    src = fetchFromGitHub {
      owner = "trevarj";
      repo = "tmux-open-nvim";
      rev = "<40-char-sha>";
      fetchSubmodules = false;
      sha256 = "sha256-...=";
    };
    date = "2026-04-20";
  };
  # ... rest similar
}
```

`_sources/nvfetcher.json` (nvfetcher's lock file) is also committed alongside.

## Package file restructure

Each package's `default.nix` consumes a `sources` arg passed by the overlay/callPackage. The arg is the result of importing `_sources/generated.nix`.

### `packages/beads-web/default.nix`

```nix
{ lib, stdenv, sources }:

let
  current =
    {
      aarch64-darwin = sources.beads-web-darwin-arm64;
      x86_64-linux = sources.beads-web-linux-x64;
    }
    .${stdenv.hostPlatform.system}
      or (throw "beads-web: ${stdenv.hostPlatform.system} not supported; build platforms: aarch64-darwin, x86_64-linux");
in
stdenv.mkDerivation {
  pname = "beads-web";
  inherit (current) version;
  inherit (current) src;

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    install -m755 $src $out/bin/beads-web
  '';

  meta = with lib; {
    description = "Visual Kanban UI for Beads CLI — real-time sync, epic tracking, GitOps";
    homepage = "https://github.com/weselow/beads-web";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "beads-web";
    platforms = [ "aarch64-darwin" "x86_64-linux" ];
  };
}
```

Net change vs. post-Chunk-3 version: signature gains `sources`, loses `fetchurl`; the inline `supportedPlatforms` attrset is replaced with system → sources.<name>; `inherit (current) version src;` lifts both fields from the nvfetcher entry.

### `packages/gascity/default.nix`

Same shape as beads-web, with three differences carried forward from the current file:
- signature is `{ lib, stdenvNoCC, sources }:` (current gascity uses `stdenvNoCC` because the tarball contains a prebuilt static binary — preserve that).
- `sourceRoot = ".";` and `dontFixup = true;` (carry over).
- `installPhase` installs `gc` (not `gascity`) — the binary inside the tarball is named `gc`. `mainProgram = "gc"`.

The `meta.platforms = [ "aarch64-darwin" "x86_64-linux" ];` is now a literal list (was derived from `supportedPlatforms` keys in Chunk 3) — minor regression of Chunk 3's no-drift property, but the source-of-truth is now `nvfetcher.toml` which has one entry per platform, so divergence would surface there.

### `packages/cmux/default.nix`

Single platform (`aarch64-darwin` per Chunk 3). Simpler:

```nix
{ lib, stdenvNoCC, undmg, sources }:

stdenvNoCC.mkDerivation {
  pname = "cmux";
  inherit (sources.cmux) version src;

  nativeBuildInputs = [ undmg ];

  unpackPhase = ''
    runHook preUnpack
    undmg "$src"
    runHook postUnpack
  '';

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/Applications $out/bin
    cp -r *.app $out/Applications/
    ln -s $out/Applications/cmux.app/Contents/Resources/bin/cmux $out/bin/cmux
    ln -s $out/Applications/cmux.app/Contents/Resources/bin/claude $out/bin/cmux-claude
  '';

  meta = with lib; {
    description = "Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents";
    homepage = "https://github.com/manaflow-ai/cmux";
    license = licenses.agpl3Plus;
    platforms = platforms.darwin;
  };
}
```

### tmux plugins (3 files)

`packages/tmux-open-nvim/default.nix`:

```nix
{ lib, tmuxPlugins, sources }:

tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-open-nvim";
  version = "unstable-${sources.tmux-open-nvim.date}";
  src = sources.tmux-open-nvim.src;
  meta = {
    platforms = lib.platforms.unix;
  };
}
```

Same shape for `tmux-mouse-swipe` and `tmux-nerd-font-window-name` (substitute name + plugin name).

The `.date` field is emitted automatically by nvfetcher for `src.git` sources (default format `%Y-%m-%d`), so `version = "unstable-${sources.X.date}"` preserves the existing `unstable-YYYY-MM-DD` convention without any `passthru` plumbing. Confirmed against the iynaix/dotfiles real-world `_sources/generated.nix` output (`mpv-deletefile.date = "2025-12-06"` etc.).

### `packages/bat-gherkin-syntax/default.nix`

```nix
{ lib, sources }:
# last updated: derived from sources.bat-gherkin-syntax at nvfetcher time
sources.bat-gherkin-syntax.src // {
  meta = {
    platforms = lib.platforms.unix;
  };
}
```

The current bat-gherkin-syntax is a bare `fetchFromGitHub` result with `meta` smuggled in (deepdive B8 flagged this). nvfetcher's `src` is also a `fetchFromGitHub` result. The simplest: expose `sources.bat-gherkin-syntax.src` directly with the smuggled `meta` re-applied via `//` merge — the result is an attrset that retains the derivation's evaluable shape (`type = "derivation"`, `outPath`, `drvPath`, ...) while letting nix tools read `meta.platforms` off the merged attrset. Wrapping in `runCommand` would give it a proper pname/version, but that's B8 territory — defer for now. (Implementer: if `nix build .#bat-gherkin-syntax` fails because the `//` discards the derivation marker, switch to `sources.bat-gherkin-syntax.src.overrideAttrs (_: { meta = { platforms = lib.platforms.unix; }; })` which preserves derivation-ness explicitly.)

## `flake.nix` changes

### Inputs

No nixpkgs/flake input changes. nvfetcher is invoked at update time, not eval time.

### devShell

Add `pkgs.nvfetcher` to `extraInputs` for laptop convenience:

```nix
extraInputs = [
  pkgs.jq
  pkgs.curl
  pkgs.gnused
  pkgs.nvfetcher
];
```

(Per Chunk 1 Task 4 bootstrap principle, `update-locks.sh` still uses `nix run nixpkgs#nvfetcher` rather than relying on devShell. devShell entry is just for the human's convenience when running `nvfetcher` manually.)

### Overlay (`overlays.default`)

Inject `sources` into every package's callPackage:

```nix
overlays.default =
  final: prev:
  let
    sources = final.callPackage ./_sources/generated.nix { };
  in
  {
    beads-web = final.callPackage ./packages/beads-web { inherit sources; };
    bat-gherkin-syntax = final.callPackage ./packages/bat-gherkin-syntax { inherit sources; };
    gascity = final.callPackage ./packages/gascity { inherit sources; };
    tmuxPlugins = prev.tmuxPlugins // {
      tmux-open-nvim = final.callPackage ./packages/tmux-open-nvim { inherit sources; };
      tmux-mouse-swipe = final.callPackage ./packages/tmux-mouse-swipe { inherit sources; };
      tmux-nerd-font-window-name = final.callPackage ./packages/tmux-nerd-font-window-name { inherit sources; };
    };
    yaziPlugins = prev.yaziPlugins // (
      let ours = final.callPackage ./packages/yaziPlugins { };
      in { inherit (ours) icons-brew bunny; }
    );
  }
  // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
    cmux = final.callPackage ./packages/cmux { inherit sources; };
  };
```

### Apps

Delete the three update apps:

```nix
apps = {
  # update-cmux, update-beads-web, update-gascity all deleted
};
```

(If the section becomes empty, delete the `apps =` block entirely.)

## `update-locks.sh` changes

**Delete** the two inline functions (`update_tmux_plugin`, `update_bat_syntax`).

**Delete** the 7 package-specific `ul_run_step` blocks (cmux, beads-web, gascity, 3 tmux, bat-gherkin-syntax).

**Add** one nvfetcher step (placed before the existing `nix-flake-update` step):

```bash
# Use `nix run nixpkgs#nvfetcher` (unpinned) deliberately: the updater
# must remain bootstrappable when this flake's devShell or flake.lock
# is itself the artifact being repaired. See nix-repo-base's 2026-05-29
# update-locks-resilience design (lines 35, 262).
ul_run_step "nvfetcher" \
  "update-locks: update sources via nvfetcher" \
  nix run nixpkgs#nvfetcher -- --build-dir _sources --config nvfetcher.toml
```

After this, the script has just two `ul_run_step` calls (nvfetcher + nix-flake-update). The `update_tmux_plugin`/`update_bat_syntax` shellcheck disables and helper code go away.

Expected `update-locks.sh` final size: ~50 lines (from current ~164).

## `.update-locks/steps/` cleanup

Delete the 7 stale per-step stamps:
- `bat-gherkin-syntax`
- `tmux-mouse-swipe`
- `tmux-nerd-font-window-name`
- `tmux-open-nvim`
- `update-beads-web`
- `update-cmux`
- `update-gascity`

(`nix-flake-update` stays. A new `nvfetcher` stamp appears after the first post-merge bot run.)

## Files deleted

| Path | Reason |
|---|---|
| `nix/update-cmux.sh` | Replaced by nvfetcher |
| `nix/update-cmux.nix` | App wrapper no longer needed |
| `nix/update-beads-web.sh` | Replaced by nvfetcher |
| `nix/update-beads-web.nix` | App wrapper no longer needed |
| `nix/update-gascity.sh` | Replaced by nvfetcher |
| `nix/update-gascity.nix` | App wrapper no longer needed |
| `.update-locks/steps/bat-gherkin-syntax` | Stale stamp |
| `.update-locks/steps/tmux-mouse-swipe` | Stale stamp |
| `.update-locks/steps/tmux-nerd-font-window-name` | Stale stamp |
| `.update-locks/steps/tmux-open-nvim` | Stale stamp |
| `.update-locks/steps/update-beads-web` | Stale stamp |
| `.update-locks/steps/update-cmux` | Stale stamp |
| `.update-locks/steps/update-gascity` | Stale stamp |

(Also the `nix/` directory itself becomes empty after the 6 file removals — delete if so.)

## Files added

| Path | Reason |
|---|---|
| `nvfetcher.toml` | Source manifest |
| `_sources/generated.nix` | Generated by nvfetcher; committed |
| `_sources/nvfetcher.json` | nvfetcher's lock; committed |

## Bootstrap principle (Chunk 1 Task 4 carry-forward)

`update-locks.sh` calls `nix run nixpkgs#nvfetcher` (unpinned) for the same reason it calls `nix run nixpkgs#nix-prefetch-github`: the updater must remain runnable when this flake's devShell or `flake.lock` is itself the artifact being repaired. nvfetcher comes from nixpkgs (trusted curated channel, not a personal repo); the security risk is small, the self-repair value is large.

`pkgs.nvfetcher` in `extraInputs` is for human convenience when running nvfetcher manually from devShell. The two paths coexist deliberately.

## Verification

1. `nvfetcher.toml` exists with the 9 entries shown above.
2. Running `nvfetcher` (from the worktree, in devShell) produces `_sources/generated.nix` and `_sources/nvfetcher.json`; both committed.
3. `nix flake check` (without `--no-build`) exits 0, building the linting derivation cleanly.
4. `nix build .#beads-web --no-link` succeeds on linux (uses `sources.beads-web-linux-x64`).
5. `nix build .#tmux-open-nvim --no-link` succeeds on linux.
6. `nix build .#bat-gherkin-syntax --no-link` succeeds on linux.
7. On darwin (or via eval-check): `nix build .#cmux --no-link` or `nix eval --raw .#cmux.drvPath`.
8. `meta.platforms` still matches Chunk 3's claims (`["aarch64-darwin", "x86_64-linux"]` for beads-web/gascity; `platforms.unix` for bat-gherkin/tmux; `platforms.darwin` for cmux).
9. The three nix/update-*.sh and three nix/update-*.nix files are gone (`ls nix/` should fail or show empty — and the `nix/` directory itself is removed).
10. `update-locks.sh` size ~50 lines; only two `ul_run_step` calls.
11. `git grep update_tmux_plugin update-locks.sh` returns nothing.
12. CI on `main` is green after merge.

## Risk / Rollback

- **nvfetcher's git source for branch-tip packages**: nvfetcher resolves the current branch tip at run time. If a tmux plugin upstream has pushed bad code, the next nvfetcher run could pull it in. This is the same risk as today's branch-tip pinning; not regressed.
- **`_sources/generated.nix` schema may differ from spec example**: the implementer verifies the exact shape after running `nvfetcher` once and adjusts package files to match. Expected shape based on nvfetcher 0.6+'s output; could be slightly different.
- **The tmux plugin `version` derivation may need passthru.date**: nvfetcher's git source emits a `version` (sha) by default, and per the nvfetcher manifest spec, `passthru.date = ...` can be used to inject custom fields. If `version = "unstable-${sources.X.date}"` doesn't work, the package file falls back to a bare `version` from the sha. Implementer verifies empirically.
- **bat-gherkin-syntax bare-fetchFromGitHub-with-meta-smuggling** (deepdive B8) is preserved with a TODO comment for a future cleanup chunk.
- **Rollback**: `git revert`. All packages return to per-package hashes inline; the 6 update-*.sh files come back; update-locks.sh's inline functions return. The `_sources/` directory and `nvfetcher.toml` are deleted by the revert.

## Cross-Cutting

### Implementer prompt hygiene (lessons forward)

- **No PRs**; push branch, human merges.
- **CI doesn't trigger on feature branches**; verify locally.
- **`nix flake check` WITHOUT `--no-build`** (Chunk 3 lesson — `--no-build` skips building the `check-linting` derivation, which is what catches statix W04 errors).
- **Vault key infra workaround** if `nix fmt` errors on the remote builder.
- **Use Edit, not Write,** for surgical changes to existing files.

### Out-of-scope adjacent items intentionally NOT touched

- S3/M6 provenance verification — future chunk.
- B8 (bat-gherkin-syntax bare-fetch) — preserved as-is.
- A4 (prune nix-repo-base transitive inputs) — backlog.
- A5/A7 (top-level squatting, gascity zombie) — backlog.
- Branch protection on main.

## Success Criteria

After the branch is merged:
1. `nvfetcher.toml` and `_sources/generated.nix` exist at repo root and `_sources/` respectively.
2. The three `nix/update-*.sh` and three `nix/update-*.nix` files are deleted (six files total, leaving `nix/` empty — delete the directory too).
3. `update-locks.sh` has only two `ul_run_step` calls (nvfetcher + nix-flake-update); the two inline functions are gone.
4. All 8 packages still build successfully on their declared platforms (post-merge CI exercises them).
5. `git grep -E '(update_tmux_plugin|update_bat_syntax|update-cmux\.sh|update-beads-web\.sh|update-gascity\.sh)' --` returns nothing.
6. `nix run nixpkgs#nvfetcher` from inside the worktree produces a no-op or a fresh `_sources/generated.nix` (depending on upstream movements).
7. CI on main is green.

## Open Questions

None pending. Decisions resolved in dialogue:
- Branch granularity: single big-bang branch.
- S3/M6 provenance: deferred.
- yaziPlugins not in scope (in-repo paths).
- Bootstrap principle preserved: `nix run nixpkgs#nvfetcher` in `update-locks.sh`; `pkgs.nvfetcher` in devShell for convenience.
- `_sources/generated.nix` committed (standard nvfetcher idiom).

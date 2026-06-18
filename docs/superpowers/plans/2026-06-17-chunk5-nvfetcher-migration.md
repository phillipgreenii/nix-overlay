# Chunk 5: nvfetcher Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three bespoke updater apps (`nix/update-{cmux,beads-web,gascity}.{sh,nix}`) and the two inline `update_tmux_plugin` / `update_bat_syntax` shell functions in `update-locks.sh` with a single `nvfetcher.toml` manifest plus a committed `_sources/generated.nix`, then rewire each of the seven external-source packages to consume a `sources` argument injected by the overlay.

**Architecture:** Single local branch `feat/nvfetcher` off `origin/main`. One big-bang branch — the seven package edits + flake edits + script deletions + manifest creation are tightly coupled (a half-migrated state does not build). Push to `origin` for human-merge. CI does not trigger on feature branches; verification is local via `nix flake check` (without `--no-build` — Chunk 3 lesson) plus per-package `nix build`.

**Tech Stack:** TOML (nvfetcher manifest), Nix (overlay + package files), Bash (updater script). nvfetcher itself is invoked via `nix run nixpkgs#nvfetcher` (bootstrap-safe; same pattern as `nix run nixpkgs#nix-prefetch-github` it replaces).

**Source spec:** `docs/superpowers/specs/2026-06-17-chunk5-nvfetcher-migration-design.md`
**Source review:** `2026-06-12-nix-overlay-deepdive.md` (findings M1, A3, B7)

## Global Constraints

These apply to every step; the implementer must internalize them before starting.

- **Work in the worktree at `/home/tcadmin/workspace/nix-overlay-chunk1`.** The sibling main checkout at `/home/tcadmin/workspace/nix-overlay` is separate; do not `cd` there. `main` is checked out in the sibling — you cannot `git checkout main` in this worktree. Branch directly off `origin/main` with `git checkout -b feat/nvfetcher origin/main`.
- **No pull requests.** Never run `gh pr create` / `gh pr merge` / `gh pr` of any kind. Your job ends with `git push`; the human merges to `main` locally and pushes.
- **CI does not run on feature branches.** `.github/workflows/ci.yml` triggers only on push-to-main and PRs-against-main. Do NOT run `gh run watch` — it hangs forever. Verification is local: `nix flake check --show-trace` and `nix build .#<pkg> --no-link`.
- **Run `nix flake check` WITHOUT `--no-build`.** Chunk 3 lesson: `--no-build` skips the `check-linting` derivation, masking statix W04 errors. Always full-build.
- **Vault key infra issue.** The remote builder `192.168.2.53` has been failing on derivations requiring `/run/vault-secrets/nix-signing-key.sec`. If `nix fmt`, `nix flake check`, or `nix build` fails with "No such file or directory" for that path, retry with `--builders '' --max-jobs 4` to force local execution.
- **Use the Edit tool for surgical changes to existing files.** Use Write only for the brand-new `nvfetcher.toml`. `_sources/generated.nix` and `_sources/nvfetcher.json` are *generated* by `nvfetcher` itself — do not Write them by hand. After nvfetcher runs you read them back and adjust the package files to match the actual emitted shape if it differs from this plan's expectations.
- **Bootstrap principle.** The new `update-locks.sh` step calls `nix run nixpkgs#nvfetcher` (unpinned, same pattern as the old `nix run nixpkgs#nix-prefetch-github` calls). The flake's devShell ALSO ships `pkgs.nvfetcher` for human convenience. Both coexist intentionally.
- **Do NOT touch:** `treefmt.nix`, `flake.lock` (let nvfetcher leave it alone; the existing `nix-flake-update` step still runs after), `.github/workflows/`, `firefox-binary-wrapper` overlay, `yaziPlugins` package (in-repo path, not external — out of scope), `homeModules`, `legacyPackages`, `checks`, `pre-commit` wiring, `install-pre-commit-hooks`, `fix-lint`. Beads/secrets/auth: none touched.

## Preconditions

1. The spec branch (which also contains this plan) has been merged into `main` and pushed by the human reviewer. The implementation branch branches from the post-merge main so the docs travel with the code.
2. Worktree exists at `/home/tcadmin/workspace/nix-overlay-chunk1`. (Existed from Chunks 1–4; reused.)
3. Post-Chunk-4 `main` HEAD is current. Verify with `git log --oneline origin/main -3` after fetch.
4. `gh` CLI is authenticated as a user with write access to `phillipgreenii/nix-overlay`.
5. `nix run nixpkgs#nvfetcher -- --help` succeeds (i.e. nvfetcher is reachable via the current nix channel registry — required for the very first run in Step 4).

---

## Task: Chunk 5 — nvfetcher migration (single branch)

**Why one branch:** the seven package files all change signature (`sources` is a new required arg) in lockstep with the overlay's `callPackage` call. Splitting per-package would leave the tree non-evaluating between commits. Single branch, single push.

**Files:**
- Create: `nvfetcher.toml` (root)
- Create (via running `nvfetcher`): `_sources/generated.nix`, `_sources/nvfetcher.json`
- Modify: `flake.nix`, `update-locks.sh`, all 7 of `packages/{beads-web,gascity,cmux,bat-gherkin-syntax,tmux-open-nvim,tmux-mouse-swipe,tmux-nerd-font-window-name}/default.nix`
- Delete (index + on-disk): `nix/update-{cmux,beads-web,gascity}.{sh,nix}` (6 files); the `nix/` directory after it's empty; the 7 stale step files under `.update-locks/steps/` (`bat-gherkin-syntax`, `tmux-mouse-swipe`, `tmux-nerd-font-window-name`, `tmux-open-nvim`, `update-beads-web`, `update-cmux`, `update-gascity`)

**Interfaces:**
- Consumes: post-Chunk-4 state — beads-web/gascity use `supportedPlatforms` attrset; cmux declares `platforms.darwin`; tmux plugins + bat-gherkin-syntax declare `platforms.unix`; overlay is inverted (`final.callPackage ./packages/X { }` form); update-locks.sh sources nix-repo-base's `update-locks-lib.bash` and uses `ul_run_step` for staged checkpoints.
- Produces: a single `nvfetcher.toml` driving all source pinning; per-package files that take a `sources` argument; `update-locks.sh` with only 2 `ul_run_step` calls (nvfetcher + nix-flake-update); 6 fewer files under `nix/`; the `nix/` directory removed; 7 fewer stale stamps under `.update-locks/steps/`.

**Branch:** `feat/nvfetcher`

### Steps

- [ ] **Step 1: Create branch off updated origin/main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git fetch origin
git checkout -b feat/nvfetcher origin/main
git log --oneline origin/main -3
git status
```

Expected: clean working tree on branch `feat/nvfetcher`. If `git checkout` reports "your local changes would be overwritten", investigate — the worktree should be clean from Chunk 4's completion; do not blow it away without checking.

- [ ] **Step 2: Confirm current state matches plan assumptions**

```bash
# Sanity-check the things we're about to delete actually exist
ls nix/update-cmux.sh nix/update-cmux.nix nix/update-beads-web.sh nix/update-beads-web.nix nix/update-gascity.sh nix/update-gascity.nix

# update-locks.sh has the two inline functions and the 7 ul_run_step blocks
grep -nE 'update_tmux_plugin|update_bat_syntax' update-locks.sh | head -20
grep -nE 'ul_run_step' update-locks.sh

# Stale step files exist (we delete all of these except nix-flake-update)
ls .update-locks/steps/

# nvfetcher.toml does NOT yet exist
test ! -f nvfetcher.toml && echo "OK: no nvfetcher.toml yet"
test ! -d _sources && echo "OK: no _sources/ yet"
```

Expected: 6 files under `nix/`; `update_tmux_plugin` defined around line 52, `update_bat_syntax` around line 93, 7 `ul_run_step` blocks for the per-package steps + 1 for `nix-flake-update`; 8 stale step files (7 to delete, 1 — `nix-flake-update` — to keep); no `nvfetcher.toml` or `_sources/`.

If any expectation fails, STOP and ask the user — the repo state has drifted.

- [ ] **Step 3: Write `nvfetcher.toml`**

Use Write tool to create the new file at the repo root with EXACTLY this content:

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

Notes for the implementer:
- `$ver` is the documented nvfetcher substitution variable; do NOT use `${ver}` or `$version`.
- `src.github_tag` (not `src.github_release` — that key does not exist; the documented key for "latest GitHub release" is `src.github`, but tag-based tracking is the safer, more widely-used convention; it also pairs cleanly with `src.prefix = "v"` to strip the leading `v` so `$ver` is the bare semver like `0.11.2`).
- For the binary-release packages (`fetch.url`), the URL templating uses `$ver` directly — multiple occurrences in one URL all substitute (verified against iynaix/dotfiles `helium-$ver-x86_64.AppImage` pattern).
- For the git-branch packages (`fetch.github`), no `$ver` is needed in the fetcher — nvfetcher resolves `src.git` to a rev and feeds it to `fetchFromGitHub` automatically.

- [ ] **Step 4: Run nvfetcher to generate `_sources/`**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
nix run nixpkgs#nvfetcher -- --build-dir _sources --config nvfetcher.toml
```

Expected: nvfetcher prints per-package "checked" / "fetched" lines for all 9 entries, then writes `_sources/generated.nix` and `_sources/nvfetcher.json`. The whole run takes 30s–2min on a fresh cache.

If the run fails:
- Network/DNS issue → retry; nvfetcher is idempotent.
- Vault key error on a remote builder → re-run with `nix run nixpkgs#nvfetcher --builders '' --max-jobs 4 -- --build-dir _sources --config nvfetcher.toml` (force local).
- Unrecognized TOML key → re-read Step 3, fix the typo. Do NOT invent new keys.
- An asset 404s (e.g. cmux-macos.dmg URL changed upstream) → STOP and ask the user. We do not want to silently track a different artifact.

After the run, verify the output shape:

```bash
ls _sources/
# Expected: generated.nix nvfetcher.json
head -15 _sources/generated.nix
# Expected: function signature `{ fetchgit, fetchurl, fetchFromGitHub, dockerTools }:` (single-line or multi-line form, both valid)
```

Open `_sources/generated.nix` with the Read tool and inspect it. Confirm:
- Each of the 9 entries has `pname`, `version`, `src`.
- The 4 git-branch entries (3 tmux plugins + bat-gherkin-syntax) ALSO have a `date = "YYYY-MM-DD"` field.
- The 5 binary entries (2 beads-web + 2 gascity + cmux) use `fetchurl` (no `date`).

If the date field is named differently or absent, adjust Steps 9–11 accordingly. The spec's expectation is based on nvfetcher 0.6+ output verified against real-world repos; the shape should match.

- [ ] **Step 5: Rewrite `packages/beads-web/default.nix`**

Use the Write tool (the file changes substantially; not a surgical edit). Replace the whole file with:

```nix
{
  lib,
  stdenv,
  sources,
}:

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
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
  };
}
```

Net changes vs. the post-Chunk-3 file: signature gains `sources`, loses `fetchurl`; the `supportedPlatforms`/`hash`/url-template scaffolding collapses to a 2-line system-keyed attrset; `inherit (current) version src` lifts both fields from the nvfetcher entry. `meta.platforms` becomes a literal list (was `builtins.attrNames supportedPlatforms` in Chunk 3 — a minor regression of the no-drift property, accepted because the source-of-truth is now `nvfetcher.toml`).

- [ ] **Step 6: Rewrite `packages/gascity/default.nix`**

Write the whole file:

```nix
{
  lib,
  stdenvNoCC,
  sources,
}:

let
  current =
    {
      aarch64-darwin = sources.gascity-darwin-arm64;
      x86_64-linux = sources.gascity-linux-amd64;
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "gascity: ${stdenvNoCC.hostPlatform.system} not supported; build platforms: aarch64-darwin, x86_64-linux");
in
stdenvNoCC.mkDerivation {
  pname = "gascity";
  inherit (current) version;
  inherit (current) src;

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/bin
    install -m755 gc $out/bin/gc
  '';

  meta = with lib; {
    description = "Orchestration-builder SDK for multi-agent systems";
    homepage = "https://github.com/gastownhall/gascity";
    license = licenses.mit;
    mainProgram = "gc";
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
  };
}
```

Carries forward: `stdenvNoCC` (binary is prebuilt, no compiler needed); `sourceRoot = "."`; `dontFixup = true`; binary is named `gc` (not `gascity`).

- [ ] **Step 7: Rewrite `packages/cmux/default.nix`**

Write the whole file:

```nix
{
  lib,
  stdenvNoCC,
  undmg,
  sources,
}:
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

Net changes vs. post-Chunk-3 file: signature drops `fetchurl`, adds `sources`; `rec` is removed (no longer needed since `version` doesn't reference itself); `inherit (sources.cmux) version src` replaces the literal `version = "0.64.16"` and the inline `fetchurl { ... }`.

- [ ] **Step 8: Rewrite `packages/tmux-open-nvim/default.nix`**

Write the whole file:

```nix
{
  lib,
  tmuxPlugins,
  sources,
}:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-open-nvim";
  version = "unstable-${sources.tmux-open-nvim.date}";
  src = sources.tmux-open-nvim.src;
  meta = {
    platforms = lib.platforms.unix;
  };
}
```

Net changes: signature drops `fetchFromGitHub`, adds `sources`; the inline `fetchFromGitHub { owner = ...; repo = ...; rev = ...; sha256 = ...; }` becomes `sources.tmux-open-nvim.src`; the literal `unstable-2026-04-20` becomes `unstable-${sources.tmux-open-nvim.date}` (nvfetcher's git-source `date` field, format `YYYY-MM-DD`).

If, after Step 4 inspection, the `date` field is absent from the generated.nix entry, fall back to `version = "unstable-${sources.tmux-open-nvim.version}"` (a 40-char sha — uglier but valid).

- [ ] **Step 9: Rewrite `packages/tmux-mouse-swipe/default.nix`**

Write the whole file:

```nix
{
  lib,
  tmuxPlugins,
  sources,
}:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-mouse-swipe";
  version = "unstable-${sources.tmux-mouse-swipe.date}";
  src = sources.tmux-mouse-swipe.src;
  meta = {
    platforms = lib.platforms.unix;
  };
}
```

Same fallback as Step 8 if `.date` is missing.

- [ ] **Step 10: Rewrite `packages/tmux-nerd-font-window-name/default.nix`**

Write the whole file:

```nix
{
  lib,
  tmuxPlugins,
  sources,
}:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-nerd-font-window-name";
  version = "unstable-${sources.tmux-nerd-font-window-name.date}";
  src = sources.tmux-nerd-font-window-name.src;
  meta = {
    platforms = lib.platforms.unix;
  };
}
```

Same fallback as Step 8 if `.date` is missing.

- [ ] **Step 11: Rewrite `packages/bat-gherkin-syntax/default.nix`**

Write the whole file:

```nix
{
  lib,
  sources,
}:
# Bare fetchFromGitHub result with smuggled meta (deepdive B8 — deferred).
# The // merge re-applies meta on top of the source derivation. If
# `nix build .#bat-gherkin-syntax` fails because the // drops derivation
# markers, swap to:
#   sources.bat-gherkin-syntax.src.overrideAttrs (_: {
#     meta = { platforms = lib.platforms.unix; };
#   })
sources.bat-gherkin-syntax.src // {
  meta = {
    platforms = lib.platforms.unix;
  };
}
```

Net changes: signature drops `fetchFromGitHub`, adds `sources`; the comment `# last updated: unstable-2024-10-12` is dropped (Chunk 3-era convention, no longer accurate now that nvfetcher tracks date in `_sources/generated.nix`); the inline `fetchFromGitHub { owner = ...; repo = ...; rev = ...; sha256 = ...; meta = { ... }; }` becomes `sources.bat-gherkin-syntax.src // { meta = { ... }; }`.

- [ ] **Step 12: Update `flake.nix` — overlay sources injection**

Use Edit. Find the `overlays.default = final: prev: { ... };` block and replace exactly:

Old:
```nix
      overlays.default =
        final: prev:
        {
          beads-web = final.callPackage ./packages/beads-web { };
          bat-gherkin-syntax = final.callPackage ./packages/bat-gherkin-syntax { };
          gascity = final.callPackage ./packages/gascity { };
          tmuxPlugins = prev.tmuxPlugins // {
            tmux-open-nvim = final.callPackage ./packages/tmux-open-nvim { };
            tmux-mouse-swipe = final.callPackage ./packages/tmux-mouse-swipe { };
            tmux-nerd-font-window-name = final.callPackage ./packages/tmux-nerd-font-window-name { };
          };
          yaziPlugins =
            prev.yaziPlugins
            // (
              let
                ours = final.callPackage ./packages/yaziPlugins { };
              in
              {
                inherit (ours) icons-brew bunny;
              }
            );
        }
        // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
          cmux = final.callPackage ./packages/cmux { };
        };
```

New:
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
          yaziPlugins =
            prev.yaziPlugins
            // (
              let
                ours = final.callPackage ./packages/yaziPlugins { };
              in
              {
                inherit (ours) icons-brew bunny;
              }
            );
        }
        // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
          cmux = final.callPackage ./packages/cmux { inherit sources; };
        };
```

The `let sources = final.callPackage ./_sources/generated.nix { }; in` form is safe: `final.callPackage` resolves `fetchgit`/`fetchurl`/`fetchFromGitHub`/`dockerTools` from the final overlay's pkgs (standard nixpkgs derivations — no overlay-defined name collides), so no infinite recursion. The `yaziPlugins` block does NOT take `sources` — yaziPlugins are in-repo, not nvfetcher-managed.

- [ ] **Step 13: Update `flake.nix` — add `pkgs.nvfetcher` to devShell**

Use Edit. Find:

```nix
        devShells.default = phillipgreenii-nix-base.lib.mkDevShell {
          inherit pkgs;
          pre-commit-shellHook = pre-commit.shellHook;
          extraInputs = [
            pkgs.jq
            pkgs.curl
            pkgs.gnused
          ];
        };
```

Replace with:

```nix
        devShells.default = phillipgreenii-nix-base.lib.mkDevShell {
          inherit pkgs;
          pre-commit-shellHook = pre-commit.shellHook;
          extraInputs = [
            pkgs.jq
            pkgs.curl
            pkgs.gnused
            pkgs.nvfetcher
          ];
        };
```

- [ ] **Step 14: Update `flake.nix` — delete the three update-* apps**

Use Edit. Find:

```nix
        apps =
          let
            mkApp = drv: {
              type = "app";
              program = "${drv}/bin/${drv.meta.mainProgram or drv.name}";
            };
          in
          {
            update-cmux = mkApp (pkgs.callPackage ./nix/update-cmux.nix { });
            update-beads-web = mkApp (pkgs.callPackage ./nix/update-beads-web.nix { });
            update-gascity = mkApp (pkgs.callPackage ./nix/update-gascity.nix { });
          };
      }
```

Replace with (delete the entire `apps =` block; the trailing `};` of the per-system attrset is the next line):

```nix
      }
```

Verify the `flake.nix` per-system attrset still ends correctly. Read lines around the previous `apps =` block to confirm the closing `};` for the per-system attrset (returned to `eachDefaultSystem`) is still in place. If you accidentally remove one too many `}`, `nix flake show` will report a syntax error.

- [ ] **Step 15: Update `update-locks.sh` — delete inline functions**

Use Edit. Replace the following block (from `update-locks.sh` lines ~49–130 in the current file — the `update_tmux_plugin` function preceded by its docstring through the closing `}` of `update_bat_syntax`):

Old (the entire two-function block plus the blank line between them):

```bash
# Update a tmux plugin's sha256 and version in sync with its branch tip.
# Each plugin lives in its own file: packages/<plugin-name>/default.nix.
# shellcheck disable=SC2329
update_tmux_plugin() {
  local plugin_name="$1"
  local owner="$2"
  local repo="$3"
  local branch="${4:-main}"
  local nix_file="${SCRIPT_DIR}/packages/${plugin_name}/default.nix"

  echo "==> Updating tmux plugin ${plugin_name}..."

  # Use `nix run nixpkgs#nix-prefetch-github` (unpinned) deliberately: the
  # updater must remain bootstrappable when this flake's devShell or
  # flake.lock is itself the artifact being repaired. See nix-repo-base's
  # 2026-05-29 update-locks-resilience design (lines 35, 262).
  local prefetch_json
  prefetch_json=$(nix run nixpkgs#nix-prefetch-github -- --json --rev "$branch" "$owner" "$repo" 2>/dev/null)

  local new_rev new_hash
  new_rev=$(printf '%s' "$prefetch_json" | jq -r '.rev')
  new_hash=$(printf '%s' "$prefetch_json" | jq -r '.hash')

  local current_hash
  current_hash=$(grep 'sha256 = ' "$nix_file" | sed 's/.*sha256 = "\([^"]*\)".*/\1/')

  if [[ $new_hash == "$current_hash" ]]; then
    echo "  ✓ ${plugin_name} already up to date (${new_rev:0:7})"
    return
  fi

  local new_date
  new_date=$(curl -sf "https://api.github.com/repos/${owner}/${repo}/commits/${new_rev}" |
    jq -r '.commit.committer.date' | sed 's/T.*//')

  echo "  ${plugin_name}: updated to ${new_rev:0:7} (${new_date})"

  sed -i "s|version = \"unstable-[^\"]*\";|version = \"unstable-${new_date}\";|" "$nix_file"
  sed -i "s|sha256 = \"sha256-[^\"]*\";|sha256 = \"${new_hash}\";|" "$nix_file"
  sed -i "s|rev = \"[^\"]*\";|rev = \"${new_rev}\";|" "$nix_file"
}

# Update a bat syntax definition's sha256 and date comment in sync with branch tip.
# shellcheck disable=SC2329
update_bat_syntax() {
  local syntax_name="$1"
  local owner="$2"
  local repo="$3"
  local branch="${4:-main}"
  local nix_file="${SCRIPT_DIR}/packages/bat-gherkin-syntax/default.nix"

  echo "==> Updating bat syntax ${syntax_name}..."

  # Use `nix run nixpkgs#nix-prefetch-github` (unpinned) deliberately: the
  # updater must remain bootstrappable when this flake's devShell or
  # flake.lock is itself the artifact being repaired. See nix-repo-base's
  # 2026-05-29 update-locks-resilience design (lines 35, 262).
  local prefetch_json
  prefetch_json=$(nix run nixpkgs#nix-prefetch-github -- --json --rev "$branch" "$owner" "$repo" 2>/dev/null)

  local new_rev new_hash
  new_rev=$(printf '%s' "$prefetch_json" | jq -r '.rev')
  new_hash=$(printf '%s' "$prefetch_json" | jq -r '.hash')

  local current_hash
  current_hash=$(grep 'sha256 = ' "$nix_file" | sed 's/.*sha256 = "\([^"]*\)".*/\1/')

  if [[ $new_hash == "$current_hash" ]]; then
    echo "  ✓ ${syntax_name} already up to date (${new_rev:0:7})"
    return
  fi

  local new_date
  new_date=$(curl -sf "https://api.github.com/repos/${owner}/${repo}/commits/${new_rev}" |
    jq -r '.commit.committer.date' | sed 's/T.*//')

  echo "  ${syntax_name}: updated to ${new_rev:0:7} (${new_date})"

  sed -i "s|# last updated: unstable-[0-9-]*|# last updated: unstable-${new_date}|" "$nix_file"
  sed -i "s|sha256 = \"sha256-[^\"]*\";|sha256 = \"${new_hash}\";|" "$nix_file"
  sed -i "s|rev = \"[^\"]*\";|rev = \"${new_rev}\";|" "$nix_file"
}
```

New: (empty — both functions and the blank line between them are deleted entirely).

Edit `old_string` is the entire 82-line block above (starting from `# Update a tmux plugin's sha256 and version in sync with its branch tip.` through the closing `}` of `update_bat_syntax`); Edit `new_string` is the empty string.

Verify after the Edit that no stray code from those functions remains:

```bash
grep -nE 'update_tmux_plugin|update_bat_syntax|prefetch_json|new_rev|new_hash|new_date' update-locks.sh
```

Expected: prints nothing.

- [ ] **Step 16: Update `update-locks.sh` — replace the 7 per-package ul_run_step blocks with one nvfetcher step**

Use Edit. Find this block (originally around lines 132–158, but line numbers may shift after Step 15's deletions):

```bash
ul_run_step "update-cmux" \
  "update-locks: update cmux" \
  nix run .#update-cmux -- "${SCRIPT_DIR}"

ul_run_step "update-beads-web" \
  "update-locks: update beads-web" \
  nix run .#update-beads-web -- "${SCRIPT_DIR}"

ul_run_step "update-gascity" \
  "update-locks: update gascity" \
  nix run .#update-gascity -- "${SCRIPT_DIR}"

ul_run_step "tmux-open-nvim" \
  "update-locks: update tmux-open-nvim" \
  update_tmux_plugin "tmux-open-nvim" "trevarj" "tmux-open-nvim" "master"

ul_run_step "tmux-mouse-swipe" \
  "update-locks: update tmux-mouse-swipe" \
  update_tmux_plugin "tmux-mouse-swipe" "jaclu" "tmux-mouse-swipe" "main"

ul_run_step "tmux-nerd-font-window-name" \
  "update-locks: update tmux-nerd-font-window-name" \
  update_tmux_plugin "tmux-nerd-font-window-name" "joshmedeski" "tmux-nerd-font-window-name" "main"

ul_run_step "bat-gherkin-syntax" \
  "update-locks: update bat gherkin syntax" \
  update_bat_syntax "Gherkin" "keith-hall" "SublimeGherkinSyntax" "master"
```

Replace with:

```bash
# Use `nix run nixpkgs#nvfetcher` (unpinned) deliberately: the updater
# must remain bootstrappable when this flake's devShell or flake.lock
# is itself the artifact being repaired. See nix-repo-base's 2026-05-29
# update-locks-resilience design (lines 35, 262).
ul_run_step "nvfetcher" \
  "update-locks: update sources via nvfetcher" \
  nix run nixpkgs#nvfetcher -- --build-dir _sources --config nvfetcher.toml
```

The `nix-flake-update` ul_run_step that follows stays exactly as-is (the comment-and-block immediately after). Verify after the Edit:

```bash
grep -cE '^ul_run_step' update-locks.sh
# Expected: 2
wc -l update-locks.sh
# Expected: roughly 50–65 lines (down from 164)
```

- [ ] **Step 17: Delete the 7 stale step files**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git rm .update-locks/steps/bat-gherkin-syntax
git rm .update-locks/steps/tmux-mouse-swipe
git rm .update-locks/steps/tmux-nerd-font-window-name
git rm .update-locks/steps/tmux-open-nvim
git rm .update-locks/steps/update-beads-web
git rm .update-locks/steps/update-cmux
git rm .update-locks/steps/update-gascity

# nix-flake-update stays
ls .update-locks/steps/
# Expected: just `nix-flake-update`
```

(Chunk 4 gitignored `.update-locks/steps/` for future-created stamps but the existing tracked ones remain tracked until explicitly removed. `git rm` handles both index and on-disk.)

- [ ] **Step 18: Delete the 6 `nix/update-*.{sh,nix}` files and remove the `nix/` directory**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git rm nix/update-cmux.sh nix/update-cmux.nix
git rm nix/update-beads-web.sh nix/update-beads-web.nix
git rm nix/update-gascity.sh nix/update-gascity.nix

# nix/ should now be empty
ls nix/ 2>&1
# Expected: empty or "No such file or directory" (git may auto-remove empty dirs)

# If nix/ still exists as an empty directory on disk, remove it explicitly
[ -d nix ] && rmdir nix
```

- [ ] **Step 19: Stage the new `_sources/` and `nvfetcher.toml`**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git add nvfetcher.toml _sources/generated.nix _sources/nvfetcher.json
git status
```

Expected `git status` (summarized):
- New: `nvfetcher.toml`, `_sources/generated.nix`, `_sources/nvfetcher.json`
- Modified: `flake.nix`, `update-locks.sh`, 7 `packages/*/default.nix` files
- Deleted: 6 `nix/update-*.{sh,nix}` files, 7 `.update-locks/steps/*` files

- [ ] **Step 20: Run `nix flake check` (WITHOUT `--no-build`)**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
nix flake check --show-trace
```

Expected: exit 0. Builds the `formatting` and `linting` derivations and every package in `self.packages.${system}` (per Chunk 3's CI-builds-everything pattern).

If vault key error → retry with `--builders '' --max-jobs 4`.

If a package fails to build:
- `beads-web` / `gascity` / `cmux`: most likely the `sources.<name>.src` is a `fetchurl` result (for binary URLs) which the package expects to consume as a single file via `dontUnpack = true`. Verify the generated.nix shape and adjust.
- `tmux-*`: if `sources.<name>.date` is undefined (i.e. nvfetcher didn't emit a `date` field on this system's run), fall back to `version = "unstable-${sources.X.version}"` per Step 8's fallback note.
- `bat-gherkin-syntax`: if the `//` merge drops derivation markers and `nix build` complains the result isn't a derivation, switch to the `overrideAttrs` form from the comment in Step 11.

- [ ] **Step 21: Per-package smoke-build for the non-darwin packages**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
nix build .#beads-web --no-link --show-trace
nix build .#bat-gherkin-syntax --no-link --show-trace
nix build .#gascity --no-link --show-trace
nix build .#tmux-open-nvim --no-link --show-trace
nix build .#tmux-mouse-swipe --no-link --show-trace
nix build .#tmux-nerd-font-window-name --no-link --show-trace
nix build .#yaziPlugins-icons-brew --no-link --show-trace
nix build .#yaziPlugins-bunny --no-link --show-trace
```

Expected: all 8 succeed. `cmux` is darwin-only — skip on linux; CI on darwin matrix exercises it post-merge.

For darwin coverage: a cheap eval-time check is `nix eval --raw .#packages.aarch64-darwin.cmux.outPath` (won't build, but evaluates the derivation and proves the closure is reachable). Optional; the post-merge CI matrix is the real darwin verification.

- [ ] **Step 22: Grep checks (deletions confirmed)**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1

# No references to the deleted shell functions remain
git grep -nE 'update_tmux_plugin|update_bat_syntax' && echo "FAIL: stale references" || echo "OK"

# No references to the deleted apps remain
git grep -nE 'update-cmux\.sh|update-beads-web\.sh|update-gascity\.sh|update-cmux\.nix|update-beads-web\.nix|update-gascity\.nix' -- ':!docs/' && echo "FAIL: stale references in code" || echo "OK"
git grep -nE '#update-cmux\b|#update-beads-web\b|#update-gascity\b' && echo "FAIL: stale flake-app refs" || echo "OK"

# update-locks.sh has exactly 2 ul_run_step calls
test "$(grep -cE '^ul_run_step' update-locks.sh)" = 2 && echo "OK" || echo "FAIL: wrong ul_run_step count"

# nix/ is gone
test ! -d nix && echo "OK" || echo "FAIL: nix/ still present"

# nvfetcher.toml has 9 [section] headers
test "$(grep -cE '^\[[^]]+\]' nvfetcher.toml)" = 9 && echo "OK" || echo "FAIL: wrong section count"
```

Expected: all `OK`. (Docs may still reference the old names — that's fine; the `:!docs/` exclusion handles it.)

- [ ] **Step 23: Format and lint**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
nix fmt
# If vault key error → nix fmt --builders '' --max-jobs 4

git diff --stat
# Sanity: formatter may have rewrapped lines in flake.nix or the package files
```

- [ ] **Step 24: Final `nix flake check`**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
nix flake check --show-trace
```

Expected: exit 0, identical result to Step 20 (post-format).

- [ ] **Step 25: Commit and push**

Stage anything `nix fmt` touched and any remaining unstaged changes from Steps 5–18, then commit:

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git add -A
git status
# Verify ONLY the expected files appear: nvfetcher.toml, _sources/, flake.nix,
# update-locks.sh, 7 packages/*/default.nix, deletions under nix/ and
# .update-locks/steps/.

git commit -m "$(cat <<'EOF'
feat: migrate source pinning to nvfetcher

Replace three bespoke updater apps (nix/update-{cmux,beads-web,gascity}.{sh,nix})
and the two inline shell functions (update_tmux_plugin, update_bat_syntax) with
a single nvfetcher.toml manifest plus committed _sources/generated.nix.

- Add nvfetcher.toml with 9 entries (5 binary-release + 4 git-branch).
- Add _sources/generated.nix and _sources/nvfetcher.json (nvfetcher output).
- Rewrite 7 package files to consume a `sources` argument from the overlay.
- Inject `sources = final.callPackage ./_sources/generated.nix { }` in the
  overlay so each package gets the resolved fetcher.
- Add pkgs.nvfetcher to the devShell for human convenience.
- Shrink update-locks.sh from ~164 to ~50 lines: 2 ul_run_step calls
  (nvfetcher + nix-flake-update) instead of 7.
- Delete the three flake apps (update-cmux, update-beads-web, update-gascity)
  and the six nix/update-*.{sh,nix} files; the nix/ directory is now empty.
- Delete 7 stale .update-locks/steps/ stamps (the nix-flake-update stamp
  stays; a new `nvfetcher` stamp will appear after the first post-merge
  nightly bot run).

Addresses deepdive findings M1 (nvfetcher adoption), A3 (four near-identical
updater scripts + two near-identical sed functions), B7 (comment-as-data and
grep/sed-based Nix editing — eliminated structurally).
EOF
)"

git push -u origin feat/nvfetcher
```

If push is rejected because the branch already exists remotely, that's a previous attempt — investigate before force-pushing.

- [ ] **Step 26: Report back and STOP**

Report the branch name (`feat/nvfetcher`), commit SHA, the `_sources/generated.nix` versions resolved (especially any tmux-plugin dates that differ from the existing pre-Chunk-5 `unstable-YYYY-MM-DD` strings — that's normal drift since nvfetcher resolved current branch tips), and the line-count change for `update-locks.sh`.

**STOP HERE.** Do NOT open a pull request. Do NOT merge. Do NOT push to `main`. The human reviewer will merge `feat/nvfetcher` into `main` locally and push `main` to `origin`, at which point CI on `main` will exercise the new `_sources/` against all platforms.

---

## Post-Chunk-5 verification (run after human merges to main)

These confirm Chunk 5 was successful end-to-end. Each one is a single runnable command.

1. **Manifest exists at root:**
   `test -f nvfetcher.toml && grep -c '^\[' nvfetcher.toml`
   Expected: `9`.

2. **Generated sources are committed:**
   `test -f _sources/generated.nix && test -f _sources/nvfetcher.json`
   Expected: exit 0.

3. **Three updater scripts and three flake-app wrappers are gone:**
   `test ! -d nix`
   Expected: exit 0.

4. **`update-locks.sh` has only two `ul_run_step` calls and no inline updater functions:**
   `grep -cE '^ul_run_step' update-locks.sh; grep -E 'update_tmux_plugin|update_bat_syntax' update-locks.sh`
   Expected: `2`, then empty.

5. **No stale references to the deleted apps in any non-doc code:**
   `git grep -nE 'update-cmux\.sh|update-beads-web\.sh|update-gascity\.sh|update_tmux_plugin|update_bat_syntax' -- ':!docs/'`
   Expected: empty.

6. **All packages still build on linux:**
   `for p in beads-web bat-gherkin-syntax gascity tmux-open-nvim tmux-mouse-swipe tmux-nerd-font-window-name yaziPlugins-icons-brew yaziPlugins-bunny; do nix build .#$p --no-link || echo "FAIL: $p"; done`
   Expected: no `FAIL` lines.

7. **CI on main is green** for both linux and darwin matrices (check `gh run list --branch main --limit 1` after the human merges).

## Rollback reference

If Chunk 5 needs to be reverted post-merge: `git revert <merge-commit-sha>`. The revert restores all six `nix/update-*.{sh,nix}` files, the two inline functions in `update-locks.sh`, the seven `ul_run_step` blocks, the original package files with inline hashes, and the original overlay without `sources` injection. It deletes `nvfetcher.toml`, `_sources/generated.nix`, `_sources/nvfetcher.json`, and re-adds the seven stale step files (these will be regenerated on the next bot run anyway, so harmless). The `pkgs.nvfetcher` line in the devShell is also reverted out.

No data loss — every removed file was in git history before this chunk. The only state that isn't recoverable from `git revert` is the actual GitHub releases/tags that nvfetcher resolved at the time of the run; the post-revert package files carry the pre-Chunk-5 hashes which are still valid.

# Chunk 6: Trust & Tidy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close residual deepdive findings A5, A7, B8, B9, S6, S3/M6 plus the carryover follow-ups tc-0ixb2 and tc-34rqk in a single coherent branch.

**Architecture:** Single local branch `feat/chunk6-trust-and-tidy` off post-merge `origin/main` (the merge that brings in this docs/chunk6-spec branch). Seven items, ten tasks (one bootstrap, seven scope items, one audit-then-implement pair for S3/M6, one final verification + push). Each task ends with a commit; the entire branch is pushed once for human merge.

**Tech Stack:** Nix (flake + overlay), nvfetcher (already integrated post-Chunk-5), Bash (`update-locks.sh`, new `verify-provenance.sh`), `gh attestation verify` / `cosign verify-blob` / `curl + sha256sum` for provenance methods (per-upstream-audit-driven).

**Source spec:** `docs/superpowers/specs/2026-06-18-chunk6-trust-and-tidy-design.md`
**Source review:** `2026-06-12-nix-overlay-deepdive.md`

## Global Constraints

These apply to every task; the implementer must internalize them before starting.

- **Work in the worktree at `/home/tcadmin/workspace/nix-overlay-chunk6`.** The sibling main checkout at `/home/tcadmin/workspace/nix-overlay` is separate; do not `cd` there. `main` is checked out in the sibling — you cannot `git checkout main` in this worktree. Branch directly off `origin/main` (post-spec-merge) with `git checkout -b feat/chunk6-trust-and-tidy origin/main`.
- **No pull requests.** Never run `gh pr create` / `gh pr merge` / `gh pr` of any kind. Your job ends with `git push origin feat/chunk6-trust-and-tidy`; the human merges to `main` locally and pushes.
- **CI does not run on feature branches.** `.github/workflows/ci.yml` triggers only on push-to-main and PRs-against-main. Do NOT run `gh run watch` — it hangs forever. Verification is local: `nix flake check --show-trace -L`, `nix flake check --all-systems --show-trace -L` (eval-only), and per-package `nix build`.
- **Run `nix flake check` WITHOUT `--no-build`.** Chunk 3 lesson: `--no-build` skips the `check-linting` derivation, masking statix W04 errors. Always full-build for the local-system check (step 2 of the spec's verification battery).
- **Vault key infra issue.** The remote builder `192.168.2.53` has been failing on derivations requiring `/run/vault-secrets/nix-signing-key.sec`. If `nix fmt`, `nix flake check`, or `nix build` fails with "No such file or directory" for that path, retry with `--builders '' --max-jobs 4` to force local execution. Tracked as bead tc-ubkek.
- **Use the Edit tool for surgical changes to existing files.** Use Write only for the brand-new `verify-provenance.sh` and the test fixtures (none required here). `_sources/generated.nix` and `_sources/nvfetcher.json` are _generated_ by `nvfetcher` — do not Write them by hand.
- **Bootstrap principle (carry-over from Chunk 5).** `update-locks.sh` calls `nix run nixpkgs#nvfetcher` (unpinned, deliberate). Do not change to a pinned reference.
- **The `nix/` directory was removed in Chunk 5. Do NOT recreate it.** The new provenance helper lives at repo root: `verify-provenance.sh`.
- **Existing main CI is red** on macos-latest due to the unrelated cmux APFS regression (tc-iv7vz). This does not gate your work — you push to origin and the human merges; CI runs on the merge to main. The merge will fail on macos-latest, but that's the pre-existing failure mode, not a regression from this chunk.
- **Do NOT touch:** `overlays/firefox-binary-wrapper.nix` (B10 assertion shipped in Chunk 3 — leave alone), `homeModules`, `flake.lock` directly (let `nix flake update` do it), `legacyPackages`, the existing yaziPlugins package contents (the `callPlugin` arg change in B9 is the only edit there), `_sources/nvfetcher.json` direct edits (regenerate via nvfetcher), `beads/`.
- **Auto memory:** `feedback-use-worktrees.md` says no stash/push from a dirty main — you are already in a worktree, so this is satisfied by design.

## Preconditions

1. The spec branch `docs/chunk6-spec` (which also contains this plan) has been merged into `main` and pushed by the human reviewer. The implementation branch branches from the post-merge main so the docs travel with the code.
2. Worktree exists at `/home/tcadmin/workspace/nix-overlay-chunk6`. (Created during the spec phase; reused.) If it does not exist (e.g. removed by the human after spec merge), recreate it with `git worktree add /home/tcadmin/workspace/nix-overlay-chunk6 -b feat/chunk6-trust-and-tidy origin/main` from the sibling checkout — then skip Task 1 Step 1.
3. Post-Chunk-5 (and post-Chunk-6-spec-merge) `main` HEAD is current. Verify with `git -C /home/tcadmin/workspace/nix-overlay-chunk6 log --oneline origin/main -5` after fetch.
4. `gh` CLI is authenticated as a user with read access to `weselow/beads-web` and `manaflow-ai/cmux` (required for the Task 8 provenance audit).
5. `nix run nixpkgs#nvfetcher -- --help` succeeds.
6. The five Chunk-6-discovery beads exist: tc-iv7vz, tc-21ql1, tc-n22q9, tc-0ixb2, tc-34rqk, tc-w2pr4. (Created during brainstorm; bd verifies with `bd show tc-0ixb2 tc-34rqk` — these two are addressed by this chunk's plan.)

---

## Task 1: Branch setup + sanity checks

**Why:** Establish a clean starting state on the implementation branch before any edits. Catches a stale worktree or missed spec merge before you waste effort.

**Files:**

- Modify: (none)

**Interfaces:**

- Consumes: post-spec-merge `origin/main`
- Produces: clean working tree on branch `feat/chunk6-trust-and-tidy` rooted at the post-spec-merge HEAD

- [ ] **Step 1: Fetch and create feature branch**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk6
git fetch origin
git checkout -b feat/chunk6-trust-and-tidy origin/main
git log --oneline origin/main -5
git status
```

Expected: clean working tree on branch `feat/chunk6-trust-and-tidy`. Top of `git log` should show the spec-merge commit referencing `2026-06-18-chunk6-trust-and-tidy-design.md`. If `git checkout` reports "your local changes would be overwritten", investigate — the worktree should be clean. Do not blow it away without checking.

- [ ] **Step 2: Confirm current state matches spec assumptions**

```bash
# nvfetcher.toml exists and has the four gascity-related lines we'll delete
grep -nE '^\[(beads-web|gascity|cmux|tmux-|bat-gherkin)' nvfetcher.toml

# overlay is in current top-level-injection shape (will be reshaped by Task 3)
grep -nE 'beads-web|bat-gherkin-syntax|gascity|cmux' flake.nix | head -30

# bat-gherkin-syntax is still the bare-fetch form (will be wrapped by Task 4)
cat packages/bat-gherkin-syntax/default.nix

# id-token: write is present (will be removed by Task 6)
grep -n 'id-token' .github/workflows/update-flakes.yml

# nix/ directory does NOT exist (Chunk 5 deleted it; do not recreate)
ls nix/ 2>&1 || echo "OK: nix/ absent"

# verify-provenance.sh does NOT yet exist
ls verify-provenance.sh 2>&1 || echo "OK: verify-provenance.sh absent"
```

Expected: nvfetcher.toml has nine `[entries]`, four package files reference gascity, bat-gherkin/default.nix is the 17-line bare-fetch, id-token line found at update-flakes.yml:16, `nix/` directory absent, `verify-provenance.sh` absent. Any deviation → stop and reconcile against the spec before proceeding.

- [ ] **Step 3: No commit on this task.** Setup-only.

---

## Task 2: A7 — gascity removal

**Why:** Spec section A7. Confirmed dead at brainstorm time; removing it now (a) shrinks the surface area of the A5 namespace migration (Task 3 doesn't have to consider a gascity entry), and (b) prunes nightly download cost.

**Files:**

- Modify: `nvfetcher.toml` (delete the `[gascity-darwin-arm64]` and `[gascity-linux-amd64]` blocks)
- Modify: `_sources/generated.nix` (regenerated by nvfetcher — do not hand-edit)
- Modify: `_sources/nvfetcher.json` (regenerated by nvfetcher)
- Modify: `flake.nix` (remove `gascity` from `packages.${system}` `inherit` and from `overlays.default`)
- Delete: `packages/gascity/default.nix`
- Delete: `packages/gascity/` directory itself

**Interfaces:**

- Consumes: post-Chunk-5 nvfetcher integration
- Produces: a gascity-free tree (`nix flake show` reports no `gascity` attribute, `nvfetcher.toml` has 7 entries)

- [ ] **Step 1: Delete gascity entries from `nvfetcher.toml`**

Open `nvfetcher.toml`. Delete the two `[gascity-...]` blocks (currently lines 11–19):

```toml
[gascity-darwin-arm64]
src.github = "gastownhall/gascity"
src.prefix = "v"
fetch.url = "https://github.com/gastownhall/gascity/releases/download/v$ver/gascity_$ver_darwin_arm64.tar.gz"

[gascity-linux-amd64]
src.github = "gastownhall/gascity"
src.prefix = "v"
fetch.url = "https://github.com/gastownhall/gascity/releases/download/v$ver/gascity_$ver_linux_amd64.tar.gz"
```

After deletion, `nvfetcher.toml` should have seven `[entries]`.

- [ ] **Step 2: Regenerate `_sources/`**

```bash
nix run nixpkgs#nvfetcher -- --build-dir _sources --config nvfetcher.toml
```

Expected: nvfetcher reports `Removed gascity-darwin-arm64` and `Removed gascity-linux-amd64`. `_sources/generated.nix` and `_sources/nvfetcher.json` no longer reference gascity.

- [ ] **Step 3: Delete the package directory**

```bash
git rm -r packages/gascity/
```

Expected: `packages/gascity/default.nix` and the containing directory disappear from `git ls-files`.

- [ ] **Step 4: Remove gascity from `flake.nix` packages output**

Open `flake.nix`. Find the `packages` output (around line 69-99). The `inherit (extended)` block currently is:

```nix
inherit (extended)
  beads-web
  bat-gherkin-syntax
  gascity
  ;
```

Remove the `gascity` line:

```nix
inherit (extended)
  beads-web
  bat-gherkin-syntax
  ;
```

- [ ] **Step 5: Remove gascity from `flake.nix` overlay**

Same file, find `overlays.default` (around line 117). Remove the gascity line:

```nix
# before
gascity = final.callPackage ./packages/gascity { inherit sources; };
# after — line deleted
```

- [ ] **Step 6: Verify**

```bash
nix flake show 2>&1 | grep -i gascity || echo "OK: no gascity in flake outputs"
nix flake check --show-trace -L
```

Expected: first command prints "OK: no gascity in flake outputs". Second command passes (`nix flake check` produces no errors related to gascity; everything else still evaluates).

- [ ] **Step 7: Commit**

```bash
git add nvfetcher.toml _sources/generated.nix _sources/nvfetcher.json flake.nix
git status   # confirm packages/gascity/ deletion is staged
git commit -m "$(cat <<'EOF'
refactor: drop gascity package (A7)

gascity was confirmed decommissioned during the 2026-06-18 Chunk 6
brainstorm — no consumer flake references the package anymore. Remove
its nvfetcher entries, regenerated _sources, package directory, and
flake.nix overlay/packages references.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: A5 — namespace migration to `phillipgreenii.{...}`

**Why:** Spec section A5. Hard cutover to a namespaced attrset. Drops top-level squatting on `beads-web`, `bat-gherkin-syntax`, `cmux`. (tmuxPlugins/yaziPlugins were already correctly nested; no change there.)

**Files:**

- Modify: `flake.nix` (restructure `overlays.default` and `packages.${system}`)

**Interfaces:**

- Consumes: post-Task-2 (gascity gone) overlay shape
- Produces: overlay where `final.phillipgreenii.{beads-web, bat-gherkin-syntax}` exists on all systems, `final.phillipgreenii.cmux` exists on aarch64-darwin only (Task 5 tightens this further); `packages.${system}` mirrors the flat names

- [ ] **Step 1: Rewrite `overlays.default` to nest under `phillipgreenii`**

Open `flake.nix`. The current overlay (lines 117–146 after Task 2) reads:

```nix
overlays.default =
  final: prev:
  let
    sources = final.callPackage ./_sources/generated.nix { };
  in
  {
    beads-web = final.callPackage ./packages/beads-web { inherit sources; };
    bat-gherkin-syntax = final.callPackage ./packages/bat-gherkin-syntax { inherit sources; };
    tmuxPlugins = prev.tmuxPlugins // {
      tmux-open-nvim = final.callPackage ./packages/tmux-open-nvim { inherit sources; };
      tmux-mouse-swipe = final.callPackage ./packages/tmux-mouse-swipe { inherit sources; };
      tmux-nerd-font-window-name = final.callPackage ./packages/tmux-nerd-font-window-name {
        inherit sources;
      };
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

Replace with:

```nix
overlays.default =
  final: prev:
  let
    sources = final.callPackage ./_sources/generated.nix { };
  in
  {
    phillipgreenii =
      {
        beads-web = final.callPackage ./packages/beads-web { inherit sources; };
        bat-gherkin-syntax = final.callPackage ./packages/bat-gherkin-syntax { inherit sources; };
      }
      // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
        cmux = final.callPackage ./packages/cmux { inherit sources; };
      };
    tmuxPlugins = prev.tmuxPlugins // {
      tmux-open-nvim = final.callPackage ./packages/tmux-open-nvim { inherit sources; };
      tmux-mouse-swipe = final.callPackage ./packages/tmux-mouse-swipe { inherit sources; };
      tmux-nerd-font-window-name = final.callPackage ./packages/tmux-nerd-font-window-name {
        inherit sources;
      };
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
  };
```

Note: the trailing top-level `// prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin { cmux = ...; }` is gone — cmux is now inside `phillipgreenii`'s own darwin-gated set. (Task 5 will tighten this gate further to aarch64-darwin only.)

- [ ] **Step 2: Update `packages.${system}` to mirror via `phillipgreenii.*`**

Same file, the `packages` block (currently lines 69–99 after Task 2):

```nix
packages =
  let
    extended = pkgs.extend self.overlays.default;
  in
  {
    inherit (extended)
      beads-web
      bat-gherkin-syntax
      ;
    inherit (extended.tmuxPlugins)
      tmux-open-nvim
      tmux-mouse-swipe
      tmux-nerd-font-window-name
      ;
    yaziPlugins-icons-brew = extended.yaziPlugins.icons-brew;
    yaziPlugins-bunny = extended.yaziPlugins.bunny;

    fix-lint = pkgs.writeShellScriptBin "fix-lint" ''
      exec ${lib.getExe pkgs.statix} fix "''${@:-.}"
    '';

    install-pre-commit-hooks = pkgs.writeShellScriptBin "install-pre-commit-hooks" ''
      ${pre-commit.shellHook}
      echo "Pre-commit hooks installed successfully!"
      echo "Run 'pre-commit run --all-files' to test them."
    '';
  }
  // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
    inherit (extended) cmux;
  };
```

Becomes:

```nix
packages =
  let
    extended = pkgs.extend self.overlays.default;
  in
  {
    inherit (extended.phillipgreenii)
      beads-web
      bat-gherkin-syntax
      ;
    inherit (extended.tmuxPlugins)
      tmux-open-nvim
      tmux-mouse-swipe
      tmux-nerd-font-window-name
      ;
    yaziPlugins-icons-brew = extended.yaziPlugins.icons-brew;
    yaziPlugins-bunny = extended.yaziPlugins.bunny;

    fix-lint = pkgs.writeShellScriptBin "fix-lint" ''
      exec ${lib.getExe pkgs.statix} fix "''${@:-.}"
    '';

    install-pre-commit-hooks = pkgs.writeShellScriptBin "install-pre-commit-hooks" ''
      ${pre-commit.shellHook}
      echo "Pre-commit hooks installed successfully!"
      echo "Run 'pre-commit run --all-files' to test them."
    '';
  }
  // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
    inherit (extended.phillipgreenii) cmux;
  };
```

Only two changes from prior: `extended` → `extended.phillipgreenii` in the first `inherit` and in the cmux gate. Everything else (tmuxPlugins, yaziPlugins-\*, fix-lint, install-pre-commit-hooks) is unchanged.

- [ ] **Step 3: Verify the flat outputs**

```bash
# Overlay-derived flat packages output still resolves
nix eval --raw .#packages.aarch64-darwin.beads-web.pname 2>/dev/null || \
  nix eval --raw .#packages.x86_64-linux.beads-web.pname
# Expected: "beads-web"

nix flake show 2>&1 | head -40
# Expected: packages.<sys>.beads-web is still present (flat output mirror).
```

(The Step 4 consumer-shape eval test below is the authoritative check for the namespace move — it exercises the overlay through the same code path consumers use. Avoid hand-constructing fake `prev` attrsets to introspect the overlay directly; the overlay's `prev.lib.optionalAttrs` access depends on `prev` being a real pkgs, which a fake attrset can't satisfy.)

- [ ] **Step 4: Consumer-shape eval test (spec verification step 5)**

```bash
nix eval --impure --expr \
  'let f = builtins.getFlake "git+file:///home/tcadmin/workspace/nix-overlay-chunk6";
       sys = builtins.currentSystem;
       base = (import f.inputs.nixpkgs { system = sys; });
       pkgs = base.extend f.outputs.overlays.default;
   in pkgs.phillipgreenii.bat-gherkin-syntax.pname'
```

Expected output: `"bat-gherkin-syntax"`. This is exactly the access path nix-personal's `home/programs/bat/gherkin-syntax.nix` will use after its post-merge consumer update.

- [ ] **Step 5: Full local check**

```bash
nix flake check --show-trace -L
```

Expected: pass. Any eval error here means the overlay restructure broke something — fix before committing.

- [ ] **Step 6: Commit**

```bash
git add flake.nix
git commit -m "$(cat <<'EOF'
refactor(flake): move overlay-contributed pkgs under phillipgreenii.{...} (A5)

Hard cutover per Chunk 6 brainstorm decision (2026-06-18). Top-level
injection of beads-web, bat-gherkin-syntax, and cmux into the consumer's
pkgs namespace was deepdive finding A5 (attribute squatting). They now
live under `pkgs.phillipgreenii.{...}`. tmuxPlugins and yaziPlugins were
already nested per nixpkgs convention; unchanged. The flat
`packages.<system>.<name>` flake outputs still work because the schema
requires depth-1 derivations — only the overlay namespacing changes.

Breaking change for consumers that read `pkgs.{beads-web,
bat-gherkin-syntax, cmux}` directly. nix-personal has one such site
(home/programs/bat/gherkin-syntax.nix); it is updated as a post-merge
follow-up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: B8 — wrap `bat-gherkin-syntax` as a proper derivation

**Why:** Spec section B8. Replace the bare `sources.bat-gherkin-syntax.src // { meta = ...; }` form (which produces a store path named `source`, no `pname`/`version`) with a real `stdenvNoCC.mkDerivation`.

**Files:**

- Modify: `packages/bat-gherkin-syntax/default.nix`

**Interfaces:**

- Consumes: `sources.bat-gherkin-syntax` (post-Chunk-5 nvfetcher output: `{ pname, version, src, ... }`)
- Produces: a derivation with `pname = "bat-gherkin-syntax"`, an attached `version`, and a store path of form `bat-gherkin-syntax-<version>`

- [ ] **Step 1: Rewrite the package file**

Replace `packages/bat-gherkin-syntax/default.nix` entirely:

```nix
{
  lib,
  stdenvNoCC,
  sources,
}:
stdenvNoCC.mkDerivation {
  pname = "bat-gherkin-syntax";
  inherit (sources.bat-gherkin-syntax) version;
  src = sources.bat-gherkin-syntax.src;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r . $out/
    runHook postInstall
  '';
  meta = {
    description = "Gherkin syntax for SublimeText, consumable by bat";
    homepage = "https://github.com/keith-hall/SublimeGherkinSyntax";
    platforms = lib.platforms.unix;
  };
}
```

- [ ] **Step 2: Build and inspect the output**

```bash
nix build .#bat-gherkin-syntax --no-link --print-out-paths
```

Expected: produces a store path of form `/nix/store/<hash>-bat-gherkin-syntax-<version>`. Specifically NOT `/nix/store/<hash>-source` (the old bare-fetch form).

```bash
# Sanity check the install: $out should contain README, LICENSE, and the .sublime-syntax file
nix build .#bat-gherkin-syntax --no-link --print-out-paths | xargs ls
```

Expected: directory listing includes at least `Gherkin.sublime-syntax` (the file consumers use) and the upstream's README/LICENSE.

- [ ] **Step 3: Confirm the namespace access path works (overlap with Task 3)**

```bash
nix eval --raw .#packages.${nix eval --raw --expr 'builtins.currentSystem'}.bat-gherkin-syntax.pname
```

Expected: `bat-gherkin-syntax` (literal, not the old `source`). Run again via `phillipgreenii`:

```bash
nix eval --impure --raw --expr \
  'let f = builtins.getFlake "git+file:///home/tcadmin/workspace/nix-overlay-chunk6";
       pkgs = (import f.inputs.nixpkgs { system = builtins.currentSystem; }).extend f.outputs.overlays.default;
   in pkgs.phillipgreenii.bat-gherkin-syntax.pname'
```

Expected: `bat-gherkin-syntax`.

- [ ] **Step 4: Commit**

```bash
git add packages/bat-gherkin-syntax/default.nix
git commit -m "$(cat <<'EOF'
refactor: wrap bat-gherkin-syntax as a proper derivation (B8)

Pre-Chunk-6 the file was a bare fetchFromGitHub result with attribute-
merged meta — store path named `source`, no pname/version, no diagnostics
for consumers. Wrap as stdenvNoCC.mkDerivation; preserves existing
behavior (cp -r . \$out matches the prior implicit installation pattern)
while giving consumers a real derivation. Closes deepdive B8.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: tc-34rqk — cmux `meta.platforms` to aarch64-darwin only

**Why:** Carryover follow-up. cmux's release artifact `cmux-macos.dmg` is an Apple-Silicon-only Electron build; `platforms.darwin` claims x86_64-darwin support that the binary cannot satisfy.

**Files:**

- Modify: `packages/cmux/default.nix:33`
- Modify: `flake.nix` cmux gate (in both the overlay's `phillipgreenii.cmux` darwin block from Task 3 AND the `packages.${system}` cmux line)

**Interfaces:**

- Consumes: post-Task-3 overlay shape with `phillipgreenii.cmux` darwin-gated
- Produces: cmux present only when `stdenv.hostPlatform.system == "aarch64-darwin"`

- [ ] **Step 1: Tighten `meta.platforms` on the derivation**

Open `packages/cmux/default.nix`. Find line 33 `platforms = platforms.darwin;`. Change to:

```nix
platforms = [ "aarch64-darwin" ];
```

(The literal-list form avoids relying on an `lib.platforms.aarch64-darwin` attr that may or may not exist on the pinned nixpkgs channel.)

- [ ] **Step 2: Tighten the overlay gate**

In `flake.nix`, the `phillipgreenii` overlay block from Task 3 reads:

```nix
phillipgreenii =
  {
    beads-web = final.callPackage ./packages/beads-web { inherit sources; };
    bat-gherkin-syntax = final.callPackage ./packages/bat-gherkin-syntax { inherit sources; };
  }
  // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
    cmux = final.callPackage ./packages/cmux { inherit sources; };
  };
```

Change the gate predicate:

```nix
phillipgreenii =
  {
    beads-web = final.callPackage ./packages/beads-web { inherit sources; };
    bat-gherkin-syntax = final.callPackage ./packages/bat-gherkin-syntax { inherit sources; };
  }
  // prev.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-darwin") {
    cmux = final.callPackage ./packages/cmux { inherit sources; };
  };
```

- [ ] **Step 3: Tighten the `packages.${system}` cmux gate**

Same file, the `packages` block's trailing `// lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin { inherit (extended.phillipgreenii) cmux; }` becomes:

```nix
// lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin") {
  inherit (extended.phillipgreenii) cmux;
};
```

- [ ] **Step 4: Verify across all systems**

```bash
nix flake check --all-systems --show-trace -L
```

Expected: pass. Crucially:

```bash
nix eval --raw .#packages.x86_64-darwin.cmux.pname 2>&1 | head -3
# Expected: error: attribute 'cmux' missing
nix eval --raw .#packages.aarch64-darwin.cmux.pname 2>&1
# Expected: "cmux"  (or possibly a derivation-build error from tc-iv7vz APFS — eval works either way)
nix eval --raw .#packages.x86_64-linux.cmux.pname 2>&1 | head -3
# Expected: error: attribute 'cmux' missing
```

- [ ] **Step 5: Commit**

```bash
git add packages/cmux/default.nix flake.nix
git commit -m "$(cat <<'EOF'
refactor: cmux platforms = aarch64-darwin only (tc-34rqk)

cmux's release artifact is cmux-macos.dmg — an Apple-Silicon-only Electron
build. Prior meta.platforms = platforms.darwin advertised x86_64-darwin
support that the binary cannot satisfy. Tighten meta.platforms to a
literal [ "aarch64-darwin" ] and update both the overlay gate and the
packages.<system> gate from `isDarwin` to a system-equality check.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: B9 + S6 — nits batch

**Why:** Spec sections B9 and S6. Cosmetic cleanup batched as one commit per the brainstorm decision.

**Files:**

- Modify: `treefmt.nix:5-8`
- Modify: `packages/yaziPlugins/default.nix:35`
- Modify: `.github/workflows/ci.yml:44-46` (drop the explicit fmt step)
- Modify: `.github/workflows/update-flakes.yml:16` (drop `id-token: write`)

**Interfaces:**

- Consumes: current files
- Produces: same behavior, fewer dead lines, no FlakeHub OIDC 401 noise

- [ ] **Step 1: Audit (confirm no `stdenv.isDarwin` deprecated alias remains)**

```bash
grep -nE '\bstdenv\.isDarwin\b' flake.nix packages/ overlays/ || echo "OK: no deprecated alias"
```

Expected: prints `OK: no deprecated alias`. (The spec's deepdive B9 finding for the alias was already addressed in a prior chunk. If this grep finds matches, stop and reconcile.)

- [ ] **Step 2: `treefmt.nix` — drop redundant `package = pkgs.nixfmt;` AND now-unused `pkgs` arg**

Open `treefmt.nix`. Find the `nixfmt` block (lines 5-8):

```nix
nixfmt = {
  enable = true;
  package = pkgs.nixfmt;
};
```

Reduce to `nixfmt.enable = true;`. Removing `package = pkgs.nixfmt;` also makes the `pkgs` arg unused — drop it from the function signature too, otherwise `statix` will flag the unused destructure (W04) and `nix flake check` (no `--no-build`) will fail the linting check.

Final file:

```nix
{ ... }:
{
  projectRootFile = "flake.nix";
  programs = {
    nixfmt.enable = true;
    shellcheck.enable = true;
    shfmt.enable = true;
  };
}
```

(treefmt-nix's `evalModule pkgs ./treefmt.nix` still passes pkgs through module-eval machinery; the `{ ... }:` rest-pattern absorbs it without declaring an explicit binding.)

- [ ] **Step 3: `packages/yaziPlugins/default.nix` — drop redundant `fetchFromGitHub` from callPlugin**

Open the file. Find the function arg list and `callPlugin`:

```nix
{
  lib,
  stdenvNoCC,
  callPackage,
  fetchFromGitHub,
}:
let
  mkYaziPlugin =
    args@{ ... }:  # unchanged
  callPlugin = path: callPackage path { inherit mkYaziPlugin fetchFromGitHub; };
```

Change to:

```nix
{
  lib,
  stdenvNoCC,
  callPackage,
}:
let
  mkYaziPlugin =
    args@{ ... }:  # unchanged
  callPlugin = path: callPackage path { inherit mkYaziPlugin; };
```

(`callPackage` auto-injects `fetchFromGitHub` from pkgs; passing it explicitly was redundant.)

- [ ] **Step 4: `.github/workflows/ci.yml` — drop duplicate fmt step**

Open `.github/workflows/ci.yml`. Find lines 44-46 (the explicit fmt step):

```yaml
- name: Check formatting with treefmt
  run: |
    nix fmt -- --ci
```

Delete those three lines. (The next step, `nix flake check --show-trace -L`, runs `checks.formatting` which exercises the same derivation.)

- [ ] **Step 5: `.github/workflows/update-flakes.yml` — drop `id-token: write` (S6)**

Open `.github/workflows/update-flakes.yml:13-16`. Current:

```yaml
permissions:
  contents: write
  pull-requests: write
  id-token: write # required for FlakeHub Cache OIDC auth
```

Delete the `id-token: write` line and trailing comment:

```yaml
permissions:
  contents: write
  pull-requests: write
```

- [ ] **Step 6: Verify (local-system check + visual diff)**

```bash
git diff --stat
# Expected: 4 files modified, small line counts (1-4 each)

nix flake check --show-trace -L
# Expected: pass. (No new test fixture; the verification is that nothing broke.)
```

- [ ] **Step 7: Commit**

```bash
git add treefmt.nix packages/yaziPlugins/default.nix .github/workflows/ci.yml .github/workflows/update-flakes.yml
git commit -m "$(cat <<'EOF'
chore: nits batch + drop id-token: write (B9, S6)

- treefmt.nix: drop redundant `package = pkgs.nixfmt;` (restates default)
- packages/yaziPlugins/default.nix: drop redundant `fetchFromGitHub` from
  callPlugin's callPackage arg set; callPackage already injects it.
- .github/workflows/ci.yml: drop the standalone `nix fmt -- --ci` step;
  `checks.formatting` (run by `nix flake check`) already exercises it.
- .github/workflows/update-flakes.yml: drop the vestigial
  `id-token: write` permission. No step uses FlakeHub Cache OIDC; the
  permission generated HTTP 401 noise on every nix invocation.

Closes deepdive B9 and S6. The `stdenv.isDarwin` deprecated-alias item
from B9 was already addressed in an earlier chunk — audited 2026-06-18,
no change needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: tc-0ixb2 — missing-vs-corrupt `flake.lock` guard

**Why:** Carryover follow-up. `update-locks.sh` currently treats any failure to resolve `flake.lock` (including syntactic corruption) as "fall through to unpinned HEAD via the self-repair path". Distinguish: missing → bootstrap-OK; corrupt → abort with operator instructions.

**Files:**

- Modify: `update-locks.sh` (insert guard between line 6 and the existing line 26 NRB_REV block)

**Interfaces:**

- Consumes: current `update-locks.sh` shape
- Produces: guard that aborts on syntactic corruption; preserves missing-file bootstrap

- [ ] **Step 1: Insert the guard**

Open `update-locks.sh`. Find the insertion point by content (line numbers may shift between revisions): immediately after the `case "${1:-}" in ... esac` arg-parsing block ends, and before the `# Resolve which update-locks-lib.bash to source via the canonical flake resolver.` comment that precedes the `NRB_REV=` block. Insert:

```bash
# Guard: distinguish missing flake.lock (legitimate bootstrap) from corrupt
# flake.lock (operator must restore). The self-repair path below tolerates an
# unresolvable `phillipgreenii-nix-base.locked.rev` by falling back to unpinned
# HEAD; corruption should not be absorbed by that fallback. tc-0ixb2.
if [ -e flake.lock ]; then
  if ! jq -e '.nodes.root' flake.lock >/dev/null 2>&1; then
    echo "update-locks.sh: flake.lock is present but corrupt (not valid JSON or missing .nodes.root)." >&2
    echo "  Restore from git: git checkout HEAD -- flake.lock" >&2
    exit 1
  fi
else
  echo "update-locks.sh: flake.lock is missing; nix flake update will bootstrap it." >&2
fi
```

- [ ] **Step 2: Verify the guard catches corruption**

```bash
# Save the real lock
cp flake.lock /tmp/flake.lock.real

# Inject corruption
echo "{ broken" > flake.lock

# Expect non-zero exit and a specific message
./update-locks.sh
echo "Exit: $?"
```

Expected: exits non-zero (status 1). Output contains "flake.lock is present but corrupt" and the restoration hint.

```bash
# Restore the real lock
cp /tmp/flake.lock.real flake.lock
```

- [ ] **Step 3: Verify the guard tolerates missing (bootstrap path)**

```bash
# Move the lock aside
mv flake.lock /tmp/flake.lock.real

# Should print the bootstrap message and continue. `nix flake update` will
# regenerate the lock. NOTE: this may hit the network and take ~30 seconds;
# if you're offline, skip this step and trust the dry-run.
./update-locks.sh
echo "Exit: $?"
```

Expected: exits 0 after the rest of the script completes. Output contains "flake.lock is missing; nix flake update will bootstrap it." The script regenerates `flake.lock`.

Restore the original lock state:

```bash
# If you ran the bootstrap, just keep the regenerated lock (the bot does this in CI).
# Otherwise:
mv /tmp/flake.lock.real flake.lock
```

- [ ] **Step 4: Verify the guard is a no-op on the normal (valid) lock case**

```bash
./update-locks.sh
echo "Exit: $?"
```

Expected: exits 0. No new output from the guard (it silently passes when `jq -e '.nodes.root' flake.lock` succeeds).

- [ ] **Step 5: Commit**

```bash
git add update-locks.sh
git commit -m "$(cat <<'EOF'
fix(update-locks): guard against corrupt vs missing flake.lock (tc-0ixb2)

The self-repair path in update-locks.sh:32-39 (fall back to unpinned
HEAD when `phillipgreenii-nix-base.locked.rev` is empty) silently
absorbs any flake.lock failure mode — including syntactic corruption.
Distinguish: missing flake.lock is the legitimate fresh-clone bootstrap
case (continue, `nix flake update` regenerates it). Corrupt flake.lock
is operator-action territory; abort with a `git checkout HEAD --`
restoration hint instead of letting automation route around it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: S3/M6 — per-upstream provenance audit

**Why:** Spec section S3/M6. The verification helper (Task 9) needs a per-upstream method assignment hard-coded into it. Audit each binary upstream's current release pipeline once; record findings.

**Files:**

- Create: (no committed file; this task produces a decision recorded in the Task 9 commit message and as a comment block in `verify-provenance.sh`)

**Interfaces:**

- Consumes: nothing (research task)
- Produces: a two-line decision: `BEADS_WEB_METHOD=<attestation|checksums|sigstore|none>` and `CMUX_METHOD=<attestation|checksums|sigstore|none>`. If either is `none`, **STOP** and surface to the user before writing the helper.

- [ ] **Step 1: Audit `weselow/beads-web`**

```bash
# Get the latest release's tag
TAG=$(gh release view --repo weselow/beads-web --json tagName --jq .tagName)
echo "beads-web latest tag: $TAG"

# List assets to see if checksums.txt / attestation files are published
gh release view "$TAG" --repo weselow/beads-web --json assets --jq '.assets[].name'

# Check for GitHub artifact attestations (gh CLI ≥ 2.49)
gh attestation list --repo weselow/beads-web --owner weselow 2>&1 | head -20 || true
# Or, for a specific asset:
gh release download "$TAG" --repo weselow/beads-web --pattern 'beads-web-linux-x64' --dir /tmp/audit-bw/
gh attestation verify /tmp/audit-bw/beads-web-linux-x64 --repo weselow/beads-web 2>&1 | head -20
```

Record the answer. Method order to try: `attestation` (gh attestation succeeds) → `checksums` (an asset named `checksums.txt` / `SHA256SUMS` / similar exists) → `sigstore` (a `<asset>.sig` asset exists) → `none`.

- [ ] **Step 2: Audit `manaflow-ai/cmux`**

```bash
TAG=$(gh release view --repo manaflow-ai/cmux --json tagName --jq .tagName)
echo "cmux latest tag: $TAG"

gh release view "$TAG" --repo manaflow-ai/cmux --json assets --jq '.assets[].name'

gh release download "$TAG" --repo manaflow-ai/cmux --pattern 'cmux-macos.dmg' --dir /tmp/audit-cmux/
gh attestation verify /tmp/audit-cmux/cmux-macos.dmg --repo manaflow-ai/cmux 2>&1 | head -20
```

Record the answer the same way.

- [ ] **Step 3: Decision gate**

| Outcome                                                        | Action                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Both have a method (`attestation`, `checksums`, or `sigstore`) | Proceed to Task 9 with the two methods recorded.                                                                                                                                                                                                                                                                                                                                                                                          |
| **Either has `none`**                                          | **STOP. Pause and surface to the user.** Report which upstream(s) publish no provenance and ask: (a) ship the helper with hard-fail for that upstream (nightly bot gets stuck on it until upstream fixes), or (b) explicitly skip-with-comment for that upstream (preserves automation continuity, accepts the documented gap). The user picks; record the choice in Task 9's commit message and the helper's per-upstream comment block. |

- [ ] **Step 4: No commit on this task.** Decision is recorded in Task 9's artifacts.

---

## Task 9: S3/M6 — write `verify-provenance.sh` + integrate into `update-locks.sh`

**Why:** Spec section S3/M6. Implements the provenance-verification step that runs between `nvfetcher` and `nix-flake-update` in the nightly updater.

**Files:**

- Create: `verify-provenance.sh` (at repo root, sibling to `update-locks.sh`)
- Modify: `update-locks.sh` (insert new `ul_run_step "verify-provenance" ...`)

**Interfaces:**

- Consumes: Task 8 audit results (BEADS_WEB_METHOD, CMUX_METHOD); `_sources/generated.nix` (post-nvfetcher source state); the just-made nvfetcher commit from the prior `ul_run_step`
- Produces: a helper that verifies each binary upstream that changed in the last commit's `_sources/generated.nix` delta and exits non-zero on failure (with `git reset --hard HEAD~1` to roll back the nvfetcher commit before exit)

- [ ] **Step 1: Write `verify-provenance.sh`**

Path: `/home/tcadmin/workspace/nix-overlay-chunk6/verify-provenance.sh`. Replace `<BEADS_WEB_METHOD>` and `<CMUX_METHOD>` with the values from Task 8.

```bash
#!/usr/bin/env bash
# Provenance verification for binary upstreams (S3/M6).
# Runs after the nvfetcher step in update-locks.sh; verifies every
# configured upstream against its per-upstream method assigned at audit
# time. Verification is idempotent — runs each invocation, not just on
# source change — keeping the helper simple and the check resilient to
# nvfetcher-output-format drift.
#
# Per-upstream methods (audit 2026-06-18 — re-audit if upstream changes
# release pipeline):
#   beads-web — <BEADS_WEB_METHOD>
#   cmux      — <CMUX_METHOD>
# Git-source plugins (tmux-*, bat-gherkin-syntax) use method `git-source`
# — explicitly skipped because the nvfetcher-pinned SHA is the integrity.
#
# Exits non-zero on any verification failure AND restores tree to the
# pre-nvfetcher state via `git reset --hard HEAD~1` so the bot does not
# open a PR on bad provenance.
set -euo pipefail

# Refuse to run on a dirty tree — rollback uses `git reset --hard HEAD~1`
# which would silently destroy uncommitted edits if any existed.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "verify-provenance: refusing to run on a dirty working tree (uncommitted changes present)" >&2
  echo "  commit or stash before retrying." >&2
  exit 1
fi

# --- per-upstream method config (audit-time decision) ---
declare -A METHODS=(
  [beads-web-darwin-arm64]="<BEADS_WEB_METHOD>"
  [beads-web-linux-x64]="<BEADS_WEB_METHOD>"
  [cmux]="<CMUX_METHOD>"
  [tmux-open-nvim]="git-source"
  [tmux-mouse-swipe]="git-source"
  [tmux-nerd-font-window-name]="git-source"
  [bat-gherkin-syntax]="git-source"
)
declare -A REPOS=(
  [beads-web-darwin-arm64]="weselow/beads-web"
  [beads-web-linux-x64]="weselow/beads-web"
  [cmux]="manaflow-ai/cmux"
)

# Extract the `url = "..."` value from the source block of a given key.
# Works only for fetchurl-style binary sources (beads-web, cmux); not used
# for git-source keys (their block uses `fetchFromGitHub { owner=...; rev=...; }`
# with no `url` attribute).
extract_url() {
  local key="$1"
  awk -v key="$key" '
    $0 ~ ("^  " key " = \\{") { in_block = 1; next }
    in_block && /url = / {
      gsub(/.*url = "/, ""); gsub(/".*/, "")
      print; exit
    }' _sources/generated.nix
}

# Extract the nvfetcher-recorded sha256 (in SRI form `sha256-BASE64`).
extract_sri() {
  local key="$1"
  awk -v key="$key" '
    $0 ~ ("^  " key " = \\{") { in_block = 1; next }
    in_block && /sha256 = / {
      gsub(/.*sha256 = "/, ""); gsub(/".*/, "")
      print; exit
    }' _sources/generated.nix
}

verify_attestation() {
  local key="$1" url; url=$(extract_url "$key")
  if [ -z "$url" ]; then
    echo "verify-provenance: $key: could not extract URL from _sources/generated.nix" >&2
    return 1
  fi
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  if ! curl --location --silent --show-error --fail --output "$tmpdir/artifact" "$url"; then
    echo "verify-provenance: $key: download failed ($url)" >&2
    return 1
  fi
  if ! gh attestation verify "$tmpdir/artifact" --repo "${REPOS[$key]}" 2>&1; then
    echo "verify-provenance: $key: gh attestation verify failed" >&2
    return 1
  fi
}

verify_checksums() {
  local key="$1" url; url=$(extract_url "$key")
  if [ -z "$url" ]; then
    echo "verify-provenance: $key: could not extract URL from _sources/generated.nix" >&2
    return 1
  fi
  # nvfetcher records SRI form (`sha256-<base64>`). Convert upstream's
  # hex sha256 (the checksums.txt convention) to SRI for comparison.
  local recorded_sri; recorded_sri=$(extract_sri "$key")
  if [ -z "$recorded_sri" ]; then
    echo "verify-provenance: $key: could not extract recorded SRI hash" >&2
    return 1
  fi
  local artifact_name; artifact_name=$(basename "$url")
  local release_base="${url%/$artifact_name}"
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  if ! curl --location --silent --show-error --fail --output "$tmpdir/checksums.txt" "$release_base/checksums.txt"; then
    echo "verify-provenance: $key: failed to download checksums.txt from $release_base" >&2
    return 1
  fi
  local upstream_hex
  upstream_hex=$(awk -v name="$artifact_name" '
    { for (i = 1; i <= NF; i++) if ($i == name || $i == "*"name) { print $1; exit } }
  ' "$tmpdir/checksums.txt")
  if [ -z "$upstream_hex" ]; then
    echo "verify-provenance: $key: artifact '$artifact_name' not listed in checksums.txt" >&2
    return 1
  fi
  # Convert upstream's hex sha256 to SRI form and compare to nvfetcher record.
  local upstream_sri
  # Portable base64 (Linux `base64 -w0` ≠ macOS `base64`): pipe to `tr -d '\n'`
  upstream_sri="sha256-$(printf '%s' "$upstream_hex" | xxd -r -p | base64 | tr -d '\n')"
  if [ "$upstream_sri" != "$recorded_sri" ]; then
    echo "verify-provenance: $key: hash mismatch — nvfetcher recorded '$recorded_sri', upstream checksums.txt says '$upstream_sri' (hex: $upstream_hex)" >&2
    return 1
  fi
}

verify_sigstore() {
  local key="$1" url; url=$(extract_url "$key")
  if [ -z "$url" ]; then
    echo "verify-provenance: $key: could not extract URL from _sources/generated.nix" >&2
    return 1
  fi
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  if ! curl --location --silent --show-error --fail --output "$tmpdir/artifact" "$url"; then
    echo "verify-provenance: $key: download failed ($url)" >&2
    return 1
  fi
  if ! curl --location --silent --show-error --fail --output "$tmpdir/artifact.sig" "$url.sig"; then
    echo "verify-provenance: $key: signature download failed ($url.sig)" >&2
    return 1
  fi
  if ! cosign verify-blob --signature "$tmpdir/artifact.sig" "$tmpdir/artifact" 2>&1; then
    echo "verify-provenance: $key: cosign verify-blob failed" >&2
    return 1
  fi
}

# --- main loop: verify every configured key every run ---
fail=0
for key in "${!METHODS[@]}"; do
  method="${METHODS[$key]}"
  case "$method" in
    attestation) verify_attestation "$key" || fail=1 ;;
    checksums)   verify_checksums   "$key" || fail=1 ;;
    sigstore)    verify_sigstore    "$key" || fail=1 ;;
    git-source)
      # Intentional no-op: git-fetched sources have no separate provenance
      # artifact; the nvfetcher-pinned commit SHA is the integrity proof.
      echo "verify-provenance: $key: skipped (git source, SHA pin is integrity)"
      ;;
    none)
      echo "verify-provenance: $key: no provenance method available (audit 2026-06-18); update is gated, no PR will open" >&2
      fail=1
      ;;
    *)
      echo "verify-provenance: $key: unknown method '$method'" >&2
      fail=1
      ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  echo "verify-provenance: at least one upstream failed provenance check" >&2
  # Roll back the nvfetcher commit so the workflow's PR-creation step
  # has nothing to PR. The prior commit is the nvfetcher step (see
  # update-locks.sh: this helper runs as the next ul_run_step).
  if git rev-parse HEAD~1 >/dev/null 2>&1; then
    echo "verify-provenance: rolling back to HEAD~1" >&2
    git reset --hard HEAD~1
  fi
  exit 1
fi

echo "verify-provenance: all configured upstreams verified."
```

Make executable:

```bash
chmod +x verify-provenance.sh
```

- [ ] **Step 2: Wire into `update-locks.sh`**

Open `update-locks.sh`. After the `ul_run_step "nvfetcher" ...` block (currently ending around line 55) and before `ul_run_step "nix-flake-update" ...` (currently at line 57), insert:

```bash
ul_run_step "verify-provenance" \
  "update-locks: verify provenance of nvfetcher source updates" \
  "$SCRIPT_DIR/verify-provenance.sh"
```

(Note the quoted path — the helper script lives at repo root next to `update-locks.sh`.)

- [ ] **Step 3: Smoke-test the no-op path (current sources should verify clean)**

```bash
./update-locks.sh
echo "Exit: $?"
```

Expected: exits 0. The script prints `verify-provenance: all configured upstreams verified.` (the helper verifies every configured key every run — intentional simplification over diff-driven selection; see spec update committed alongside this plan).

- [ ] **Step 4: Hard-fail test (spec verification step 7) + rollback verification (spec step 8)**

Choose a binary upstream that uses method `checksums` (per Task 8 audit). If both binary upstreams use `attestation` or `sigstore`, swap the test approach to corrupting the URL instead — see the alternative block below.

**For `checksums` method (preferred test):**

```bash
# Capture the pre-test commit so we can verify rollback target
PRE_COMMIT=$(git rev-parse HEAD)
echo "Pre-test HEAD: $PRE_COMMIT"

# Corrupt one binary upstream's recorded sha256 (pick beads-web-linux-x64 or
# cmux, whichever uses checksums method). This simulates "nvfetcher just
# wrote a hash that doesn't match what upstream publishes".
sed -i '/beads-web-linux-x64/,/^  };$/ s|sha256 = "sha256-[^"]*"|sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="|' _sources/generated.nix
git add _sources/generated.nix
git commit -m "TEST: simulate bad nvfetcher hash output (will be reset by verify-provenance)"
TEST_COMMIT=$(git rev-parse HEAD)
echo "Test HEAD: $TEST_COMMIT"

# Run the helper
./verify-provenance.sh; rc=$?
echo "Helper exit: $rc"

# Assert rollback worked
NOW=$(git rev-parse HEAD)
echo "Post-rollback HEAD: $NOW"
git status --porcelain
```

Expected:

- `rc=1`
- Output mentions `beads-web-linux-x64: hash mismatch — nvfetcher recorded '...', upstream checksums.txt says '...'`
- Output mentions `verify-provenance: rolling back to HEAD~1`
- `NOW == PRE_COMMIT` (the TEST commit is gone)
- `git status --porcelain` is empty

If the helper exited 0, the test failed to corrupt the right upstream — re-check that `beads-web-linux-x64`'s method is `checksums` in your helper (Task 8 output) and the sed targeted the right key. If `NOW != PRE_COMMIT`, the rollback is broken — investigate `git reset --hard HEAD~1` semantics in your worktree.

**Alternative for `attestation` or `sigstore` method (URL corruption):**

If checksums method isn't in play, corrupt the URL to point at a known-bad path (e.g. swap the version in the URL to something that doesn't exist):

```bash
PRE_COMMIT=$(git rev-parse HEAD)
# Replace the cmux URL with one that 404s
sed -i 's|cmux-macos\.dmg|cmux-macos-INVALID.dmg|' _sources/generated.nix
git add _sources/generated.nix
git commit -m "TEST: corrupt URL (will be reset)"
./verify-provenance.sh; rc=$?
echo "Helper exit: $rc; HEAD now: $(git rev-parse HEAD)"
```

Expected: `rc=1`, output mentions `cmux: download failed (https://github.com/.../cmux-macos-INVALID.dmg)`, HEAD reverted to `$PRE_COMMIT`, working tree clean.

- [ ] **Step 5: Add provenance state table to README**

Open `README.md`. After the existing usage/overlay sections (locate by content — likely after the "Provided packages" or "Consumer setup" section), add a new section:

```markdown
## Provenance verification

The nightly updater (`update-locks.sh`) verifies every binary upstream's release artifact against published provenance before allowing the update PR to open. Per-upstream method assignment (audit 2026-06-18):

| Upstream          | Method               | Notes                                                                                                                                                                                                      |
| ----------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| weselow/beads-web | `<BEADS_WEB_METHOD>` | <one-line description: e.g. "GitHub artifact attestations published since vX.Y.Z" or "checksums.txt published per release" or "no provenance; nightly bot will stall on this upstream until that changes"> |
| manaflow-ai/cmux  | `<CMUX_METHOD>`      | <one-line description>                                                                                                                                                                                     |

Git-source plugins (tmux-\*, bat-gherkin-syntax) are not verified separately — the nvfetcher-pinned commit SHA is the integrity proof.

If an upstream's release pipeline changes (publishes/withdraws attestation or checksums), the helper at `verify-provenance.sh` must be re-audited. Search for "audit 2026-06-18" in that file to find the per-upstream config block.
```

Replace `<BEADS_WEB_METHOD>` / `<CMUX_METHOD>` with the Task 8 audit findings — same values as in the helper script.

- [ ] **Step 6: Commit**

```bash
git add verify-provenance.sh update-locks.sh README.md
git commit -m "$(cat <<'EOF'
feat: provenance verification for binary upstreams (S3/M6)

Adds verify-provenance.sh at repo root and wires it as a third
ul_run_step between nvfetcher and nix-flake-update in update-locks.sh.

Per-upstream method assignment (audit 2026-06-18):
  beads-web (weselow/beads-web)   — <BEADS_WEB_METHOD>
  cmux      (manaflow-ai/cmux)    — <CMUX_METHOD>

Hard-fail mode: if any changed upstream's verification fails, the helper
rolls back the prior nvfetcher commit (`git reset --hard HEAD~1`) and
exits non-zero. The workflow's Create-Pull-Request step does not fire,
so no PR opens on bad provenance.

No runtime fallback chain — each upstream is assigned exactly one
method at audit time. Methods: attestation (gh attestation verify),
checksums (cross-check against published checksums.txt), sigstore
(cosign verify-blob). Re-audit on upstream release-pipeline change.

Closes deepdive S3/M6.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Final verification battery + push

**Why:** Run the spec's full 10-step verification battery one more time end-to-end (now that all prior tasks are committed), then push the branch to origin for human merge.

**Files:**

- Modify: (none)

**Interfaces:**

- Consumes: post-Task-9 tree
- Produces: pushed branch `feat/chunk6-trust-and-tidy` on origin, ready for human merge

- [ ] **Step 1: Run the spec's verification battery (spec section "Verification")**

For each, record pass/fail. Stop and reconcile on any failure.

```bash
# 1. nix flake show
nix flake show | grep -E 'gascity|phillipgreenii' || echo "FAIL: phillipgreenii missing"
# Expect: no gascity, phillipgreenii nested under packages.<sys> visible
# (depending on `nix flake show` rendering of namespaced overlay outputs)

# 2. local-system check
nix flake check --show-trace -L
# Expect: pass

# 3. all-systems eval check
nix flake check --all-systems --show-trace -L
# Expect: pass

# 4. per-package build
nix build .#beads-web .#bat-gherkin-syntax --no-link --print-out-paths
# Expect: two store paths printed. cmux may fail on aarch64-darwin due
# to tc-iv7vz APFS regression; that is a pre-existing failure, not
# blocking this chunk.

# 5. consumer eval smoke test (the spec's step 5)
nix eval --impure --raw --expr \
  'let f = builtins.getFlake "git+file:///home/tcadmin/workspace/nix-overlay-chunk6";
       pkgs = (import f.inputs.nixpkgs { system = builtins.currentSystem; }).extend f.outputs.overlays.default;
   in pkgs.phillipgreenii.bat-gherkin-syntax.pname'
# Expect: "bat-gherkin-syntax"

# 6. update-locks no-op
./update-locks.sh
# Expect: clean run (or new source updates that verify clean)

# 7. provenance hard-fail test (covered by Task 9 Step 4 already; do not re-run)
# 8. rollback verification (covered by Task 9 Step 4 already)

# 9. corrupt-lockfile test
cp flake.lock /tmp/flake.lock.real
echo "{" > flake.lock
./update-locks.sh; rc=$?
echo "Corrupt-lock exit: $rc"
cp /tmp/flake.lock.real flake.lock
# Expect: rc=1, output contains "flake.lock is present but corrupt"

# 10. missing-lockfile test (network-bound; skip if offline)
mv flake.lock /tmp/flake.lock.real
./update-locks.sh; rc=$?
echo "Missing-lock exit: $rc"
mv /tmp/flake.lock.real flake.lock
# Expect: rc=0, output contains "flake.lock is missing"
```

- [ ] **Step 2: Confirm clean tree**

```bash
git status --porcelain
```

Expected: empty (the spec/test stash was cleaned up).

- [ ] **Step 3: Push the branch**

```bash
git push -u origin feat/chunk6-trust-and-tidy
```

Expected: push succeeds. The remote branch exists. Do NOT open a PR.

- [ ] **Step 4: Report back**

Print the following block as the final task output:

```
Chunk 6 implementation complete.
Branch: feat/chunk6-trust-and-tidy pushed to origin.
Commits:
  <hash> refactor: drop gascity package (A7)
  <hash> refactor(flake): move overlay-contributed pkgs under phillipgreenii.{...} (A5)
  <hash> refactor: wrap bat-gherkin-syntax as a proper derivation (B8)
  <hash> refactor: cmux platforms = aarch64-darwin only (tc-34rqk)
  <hash> chore: nits batch + drop id-token: write (B9, S6)
  <hash> fix(update-locks): guard against corrupt vs missing flake.lock (tc-0ixb2)
  <hash> feat: provenance verification for binary upstreams (S3/M6)

Verification battery: 8/10 pass (#7 and #8 covered in Task 9 Step 4;
all others pass). cmux build on local aarch64-darwin may fail per
pre-existing tc-iv7vz APFS regression.

Awaiting human local merge to main + post-merge consumer follow-up
(nix-personal home/programs/bat/gherkin-syntax.nix line 22:
pkgs.bat-gherkin-syntax → pkgs.phillipgreenii.bat-gherkin-syntax).
```

---

## Post-merge consumer follow-up (human-owned, NOT part of this plan's task list)

After the human merges `feat/chunk6-trust-and-tidy` to `main`, one consumer file needs updating:

- **`nix-personal/home/programs/bat/gherkin-syntax.nix:22`** — `pkgs.bat-gherkin-syntax` → `pkgs.phillipgreenii.bat-gherkin-syntax`. After `nix flake update` in nix-personal picks up the new overlay shape.

No other consumer changes needed per the spec's grep audit (homelab/nix has no direct package references; tmuxPlugins/yaziPlugins paths are unchanged).

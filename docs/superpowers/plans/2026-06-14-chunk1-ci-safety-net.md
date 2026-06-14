# Chunk 1: CI Safety Net Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the five branches that take `phillipgreenii-nix-overlay` from "CI red for a week, auto-merge ungated, time-bomb fetches" to "CI green, packages built per-platform, source revs pinned, updater lib reproducible with self-repair, main gated by branch protection."

**Architecture:** Five sequential local branches off `main`, pushed to `origin` for CI observation but no PRs opened. After each branch's CI is green, the human merges locally into `main` and pushes; the next branch is rebased off the new `main`. All work happens in the worktree `/home/tcadmin/workspace/nix-overlay-chunk1` (created via `git worktree add`). Branch order is constraint-driven: **B3 → B1 → T1 → S2 → S1+T4**.

**Tech Stack:** Nix flakes (nixpkgs-26.05-darwin), bash (`update-locks.sh`), GitHub Actions (`.github/workflows/{ci,update-flakes}.yml`), `gh` CLI for branch protection.

**Source spec:** `docs/superpowers/specs/2026-06-14-ci-safety-net-design.md`
**Source review:** `2026-06-12-nix-overlay-deepdive.md`

---

## Preconditions

1. The spec branch `docs/chunk1-ci-safety-net-spec` (which also contains this plan) has been merged into `main` and pushed. All implementation branches branch from the post-merge `main` so the spec and plan travel with the code.
2. Worktree exists at `/home/tcadmin/workspace/nix-overlay-chunk1` (created in the brainstorming session).
3. `gh` CLI is authenticated as a user with admin rights on `phillipgreenii/nix-overlay` (needed for Task 5).
4. `nix` is available; the local nix daemon is healthy.

If any precondition is unmet, stop and resolve before starting Task 1.

---

## Task 1: B3 — Flatten `yaziPlugins`, add `legacyPackages`, rewire overlay

**Why first:** `nix flake check` has hard-failed on every push since 2026-06-07 because `packages.<system>.yaziPlugins` is a nested attrset. Nothing else can land while CI is red.

**Files:**
- Modify: `flake.nix:71-73` (replace nested attrset with flat names)
- Modify: `flake.nix` between lines 89 and 91 (add `legacyPackages` per-system output)
- Modify: `flake.nix:114-134` (rewire `overlays.default` to use `final.callPackage`)

**Branch:** `fix/yaziPlugins-flatten`

### Steps

- [ ] **Step 1.1: Create branch off latest main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git fetch origin
git checkout main
git pull --ff-only origin main
git checkout -b fix/yaziPlugins-flatten
```

Expected: clean checkout on new branch.

- [ ] **Step 1.2: Verify CI is currently failing (baseline)**

```bash
nix flake check --no-build --show-trace 2>&1 | tail -20
```

Expected: error containing `Flake output 'packages.<system>.yaziPlugins' is not a derivation`. Capture this; the post-fix output must NOT contain it.

- [ ] **Step 1.3: Flatten the `yaziPlugins` nested attrset in `packages.${system}`**

Edit `flake.nix:71-73`. Replace the current 3 lines:

```nix
          yaziPlugins = {
            inherit (yaziPluginSet) icons-brew bunny;
          };
```

With:

```nix
          yaziPlugins-icons-brew = yaziPluginSet.icons-brew;
          yaziPlugins-bunny = yaziPluginSet.bunny;
```

- [ ] **Step 1.4: Add `legacyPackages` per-system output**

Edit `flake.nix`. Inside the `eachDefaultSystem` lambda, after the `packages = { ... }` block closes (currently at line 89, just before `apps = ...` on line 91), add:

```nix
        legacyPackages = {
          yaziPlugins = {
            inherit (yaziPluginSet) icons-brew bunny;
          };
        };

```

Place it between the `packages = {...};` semicolon and `apps =`. Mind the indentation (8 spaces — matches `packages` and `apps`).

- [ ] **Step 1.5: Rewire `overlays.default` to source yaziPlugins via `final.callPackage`**

Edit `flake.nix:114-134`. Replace the entire `overlays.default = ...` block:

```nix
      overlays.default =
        _final: prev:
        let
          ownPackages = self.packages.${prev.stdenv.hostPlatform.system};
        in
        {
          inherit (ownPackages) beads-web bat-gherkin-syntax gascity;
          tmuxPlugins = prev.tmuxPlugins // {
            inherit (ownPackages)
              tmux-open-nvim
              tmux-mouse-swipe
              tmux-nerd-font-window-name
              ;
          };
          yaziPlugins = prev.yaziPlugins // {
            inherit (ownPackages.yaziPlugins) icons-brew bunny;
          };
        }
        // prev.lib.optionalAttrs prev.stdenv.isDarwin {
          inherit (ownPackages) cmux c9watch-gui c9watch-cli;
        };
```

With:

```nix
      overlays.default =
        final: prev:
        let
          ownPackages = self.packages.${prev.stdenv.hostPlatform.system};
        in
        {
          inherit (ownPackages) beads-web bat-gherkin-syntax gascity;
          tmuxPlugins = prev.tmuxPlugins // {
            inherit (ownPackages)
              tmux-open-nvim
              tmux-mouse-swipe
              tmux-nerd-font-window-name
              ;
          };
          yaziPlugins = prev.yaziPlugins // (
            let ours = final.callPackage ./packages/yaziPlugins { };
            in { inherit (ours) icons-brew bunny; }
          );
        }
        // prev.lib.optionalAttrs prev.stdenv.isDarwin {
          inherit (ownPackages) cmux c9watch-gui c9watch-cli;
        };
```

Changes: `_final` → `final` on the first lambda line; the `yaziPlugins = ...` clause now uses `final.callPackage` instead of `ownPackages.yaziPlugins` (which no longer exists after Step 1.3).

- [ ] **Step 1.6: Run `nix flake check --no-build` locally**

```bash
nix flake check --no-build --show-trace
```

Expected: exits 0 with no `not a derivation` error. (Linting via statix may still emit warnings — that's pre-existing and out of scope.)

- [ ] **Step 1.7: Verify the new flat package attrs and `legacyPackages` resolve**

```bash
nix eval --raw .#yaziPlugins-icons-brew.outPath
nix eval --raw .#yaziPlugins-bunny.outPath
nix eval --raw .#legacyPackages.x86_64-linux.yaziPlugins.icons-brew.outPath
```

Each should print a `/nix/store/...` path. If any fails with "attribute missing", the flake.nix edits are incomplete.

- [ ] **Step 1.8: Verify the overlay applies cleanly to a fresh nixpkgs**

```bash
nix eval --raw --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    nixpkgs = builtins.getFlake "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    pkgs = import nixpkgs.outPath {
      system = builtins.currentSystem;
      overlays = [ flake.overlays.default ];
    };
  in pkgs.yaziPlugins.icons-brew.outPath
'
```

Expected: a `/nix/store/...` path. This confirms the overlay rewire didn't break consumer-side access.

- [ ] **Step 1.9: Format and commit**

```bash
nix fmt
git add flake.nix
git status   # confirm only flake.nix changed
git commit -m "fix(flake): flatten yaziPlugins output to satisfy packages schema

packages.<system>.yaziPlugins was a nested attrset, which nix flake check
rejects. Flatten to yaziPlugins-icons-brew / yaziPlugins-bunny in packages,
expose the structured set in legacyPackages for consumer ergonomics, and
rewire overlays.default to build yaziPlugins via final.callPackage (a
small advance against deepdive A1).

Fixes deepdive findings B3 and T2 (CI red on main since 2026-06-07).
"
```

- [ ] **Step 1.10: Push and wait for green CI**

```bash
git push -u origin fix/yaziPlugins-flatten
gh run watch
```

Expected: both matrix jobs (`nix-checks (ubuntu-latest)` and `nix-checks (macos-latest)`) succeed.

- [ ] **Step 1.11: Human-merge checkpoint**

STOP. Tell the user: "Branch 1 (B3) CI is green. Please merge `fix/yaziPlugins-flatten` to main locally, push, and confirm before I start Task 2."

Wait for confirmation before proceeding to Task 2.

---

## Task 2: B1 — Pin upstream revs for tmux plugins and bat-gherkin-syntax

**Why next:** Defuse the `rev = "master"` / `rev = "main"` time bombs before Task 3 builds these packages in CI. Otherwise an upstream push between local hash compute and CI run reds the next branch spuriously.

**Files:**
- Modify: `packages/tmux-open-nvim/default.nix:8`
- Modify: `packages/tmux-mouse-swipe/default.nix:8`
- Modify: `packages/tmux-nerd-font-window-name/default.nix:8`
- Modify: `packages/bat-gherkin-syntax/default.nix:6`
- Modify: `update-locks.sh` (add `rev` sed in `update_tmux_plugin` and `update_bat_syntax`)

**Branch:** `fix/pin-source-revs`

### Steps

- [ ] **Step 2.1: Create branch off updated main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git checkout main
git pull --ff-only origin main
git checkout -b fix/pin-source-revs
```

- [ ] **Step 2.2: Resolve current revs for all four sources**

```bash
nix run nixpkgs#nix-prefetch-github -- --json --rev master trevarj tmux-open-nvim     | jq -r '.rev + " trevarj/tmux-open-nvim"'
nix run nixpkgs#nix-prefetch-github -- --json --rev main   jaclu tmux-mouse-swipe     | jq -r '.rev + " jaclu/tmux-mouse-swipe"'
nix run nixpkgs#nix-prefetch-github -- --json --rev main   joshmedeski tmux-nerd-font-window-name | jq -r '.rev + " joshmedeski/tmux-nerd-font-window-name"'
nix run nixpkgs#nix-prefetch-github -- --json --rev master keith-hall SublimeGherkinSyntax | jq -r '.rev + " keith-hall/SublimeGherkinSyntax"'
```

Record the 4 SHAs (40-char hex strings). Call them `$REV1` through `$REV4` for the next steps.

**Important:** the existing `sha256` values in the 4 files match these resolved revs *only if no upstream push happened since the last `update-locks.sh` run*. If the hash and rev don't match, the next build will fail. To be safe, also capture the `.hash` field:

```bash
nix run nixpkgs#nix-prefetch-github -- --json --rev master trevarj tmux-open-nvim     | jq -r '.hash + " " + .rev'
```

If `.hash` differs from what's in the file, also update `sha256` in that file (use the SRI form returned by `.hash`).

- [ ] **Step 2.3: Pin rev in `packages/tmux-open-nvim/default.nix`**

Edit line 8. Replace:

```nix
    rev = "master";
```

With (substitute the actual SHA from Step 2.2):

```nix
    rev = "<REV1-actual-40-char-sha>";
```

If `sha256` also needs updating (per Step 2.2), update line 9 too.

- [ ] **Step 2.4: Pin rev in `packages/tmux-mouse-swipe/default.nix`**

Edit line 8. Replace `rev = "main";` with `rev = "<REV2>";`. Update sha256 if needed.

- [ ] **Step 2.5: Pin rev in `packages/tmux-nerd-font-window-name/default.nix`**

Edit line 8. Replace `rev = "main";` with `rev = "<REV3>";`. Update sha256 if needed.

- [ ] **Step 2.6: Pin rev in `packages/bat-gherkin-syntax/default.nix`**

Edit line 6. Replace `rev = "master";` with `rev = "<REV4>";`. Update sha256 if needed.

- [ ] **Step 2.7: Build each of the 4 packages locally to verify**

```bash
nix build .#tmux-open-nvim --no-link
nix build .#tmux-mouse-swipe --no-link
nix build .#tmux-nerd-font-window-name --no-link
nix build .#bat-gherkin-syntax --no-link
```

Each must succeed. If any fails with "hash mismatch", the sha256 was stale and Step 2.2's hash update wasn't applied — fix and retry.

- [ ] **Step 2.8: Patch `update_tmux_plugin` to also rewrite `rev`**

Edit `update-locks.sh`. Inside `update_tmux_plugin` (currently lines 38-70), after the existing `sed` for `sha256` (line 69), add one more sed line:

Find:
```bash
  sed -i "s|version = \"unstable-[^\"]*\";|version = \"unstable-${new_date}\";|" "$nix_file"
  sed -i "s|sha256 = \"sha256-[^\"]*\";|sha256 = \"${new_hash}\";|" "$nix_file"
}
```

Replace with:
```bash
  sed -i "s|version = \"unstable-[^\"]*\";|version = \"unstable-${new_date}\";|" "$nix_file"
  sed -i "s|sha256 = \"sha256-[^\"]*\";|sha256 = \"${new_hash}\";|" "$nix_file"
  sed -i "s|rev = \"[^\"]*\";|rev = \"${new_rev}\";|" "$nix_file"
}
```

- [ ] **Step 2.9: Patch `update_bat_syntax` to also rewrite `rev`**

Edit `update-locks.sh`. Inside `update_bat_syntax` (currently lines 74-106), after the existing `sed` for `sha256` (line 105), add the same sed line:

Find:
```bash
  sed -i "s|# last updated: unstable-[0-9-]*|# last updated: unstable-${new_date}|" "$nix_file"
  sed -i "s|sha256 = \"sha256-[^\"]*\";|sha256 = \"${new_hash}\";|" "$nix_file"
}
```

Replace with:
```bash
  sed -i "s|# last updated: unstable-[0-9-]*|# last updated: unstable-${new_date}|" "$nix_file"
  sed -i "s|sha256 = \"sha256-[^\"]*\";|sha256 = \"${new_hash}\";|" "$nix_file"
  sed -i "s|rev = \"[^\"]*\";|rev = \"${new_rev}\";|" "$nix_file"
}
```

- [ ] **Step 2.10: Smoke-test the patched updater functions**

Two-part test. The new `sed` pattern needs validation; the existing early-return in `update_tmux_plugin` (`update-locks.sh:57-60` exits if `new_hash == current_hash`) would skip the seds entirely if we only stale the rev, so we have to stale the hash too.

**Part A — pattern check (unit-test the sed).**

```bash
echo '    rev = "anything-old-value-here";' \
  | sed 's|rev = "[^"]*";|rev = "newvalue";|'
```

Expected output: `    rev = "newvalue";` — confirms the pattern matches and substitutes.

**Part B — integration check (run the updater).**

Save the current state:

```bash
cp packages/tmux-open-nvim/default.nix /tmp/tmux-open-nvim-saved.nix
```

Stale both `rev` AND `sha256` so the updater's early-return is bypassed:

```bash
sed -i 's|rev = "[^"]*";|rev = "master";|' packages/tmux-open-nvim/default.nix
sed -i 's|sha256 = "sha256-[^"]*";|sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA0=";|' packages/tmux-open-nvim/default.nix
```

Run the updater:

```bash
./update-locks.sh
```

Expected: the script reaches the seds (no early return), updates `rev` to the resolved SHA, and corrects `sha256` to the real upstream value. Capture and inspect the diff:

```bash
git diff packages/tmux-open-nvim/default.nix
```

The diff should show BOTH `rev = "<40-char-sha>"` and `sha256 = "sha256-<real-hash>"`. If only one changed, the new sed line isn't being reached — re-check Step 2.8.

Restore the saved file:

```bash
cp /tmp/tmux-open-nvim-saved.nix packages/tmux-open-nvim/default.nix
rm /tmp/tmux-open-nvim-saved.nix
```

- [ ] **Step 2.11: Run `nix flake check --no-build` to ensure no eval regressions**

```bash
nix flake check --no-build --show-trace
```

Expected: exits 0.

- [ ] **Step 2.12: Format and commit**

```bash
nix fmt
git add packages/tmux-open-nvim/default.nix \
        packages/tmux-mouse-swipe/default.nix \
        packages/tmux-nerd-font-window-name/default.nix \
        packages/bat-gherkin-syntax/default.nix \
        update-locks.sh
git status   # confirm only these 5 files changed
git commit -m "fix(packages): pin upstream revs for tmux plugins and bat-gherkin-syntax

Replace rev = \"master\" / rev = \"main\" with the resolved commit SHA in
the four fixed-output fetches that previously tracked branch tips. Branch
tracking left these as time bombs: each upstream push silently invalidated
the cached hash (or, worse, served a stale cached store path).

Also teach update_tmux_plugin and update_bat_syntax in update-locks.sh to
rewrite the rev attribute alongside version and sha256 so the next updater
run keeps the pin current. The resolved rev was already in scope; the
updaters just weren't writing it.

Fixes deepdive finding B1.
"
```

- [ ] **Step 2.13: Push and wait for green CI**

```bash
git push -u origin fix/pin-source-revs
gh run watch
```

Expected: both matrix jobs green.

- [ ] **Step 2.14: Human-merge checkpoint**

STOP. Tell the user: "Branch 2 (B1) CI is green. Please merge `fix/pin-source-revs` to main locally, push, and confirm before I start Task 3."

Wait for confirmation.

---

## Task 3: T1 — Build packages in CI via `checks`

**Why now:** With B3 (Task 1) and B1 (Task 2) landed, CI is green and the package set is safe to build. Add packages to `checks` so CI actually exercises them.

**Files:**
- Modify: `flake.nix:48-51`

**Branch:** `feat/ci-builds-packages`

### Steps

- [ ] **Step 3.1: Create branch off updated main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git checkout main
git pull --ff-only origin main
git checkout -b feat/ci-builds-packages
```

- [ ] **Step 3.2: Expand `checks` to include packages, with linux exclusions**

Edit `flake.nix:48-51`. Replace:

```nix
        checks = {
          formatting = treefmtEval.config.build.check self;
          linting = checks-lib.linting ./.;
        };
```

With:

```nix
        checks =
          {
            formatting = treefmtEval.config.build.check self;
            linting = checks-lib.linting ./.;
          }
          # Build every package in self.packages.${system} so CI exercises the
          # derivations, not just lint/format. On linux, exclude beads-web and
          # gascity until deepdive B5/B6 land (Chunk 3) — those packages ship
          # lib.fakeHash for linux and would always fail.
          # NOTE: if a future package name collides with "formatting" or
          # "linting", it will silently shadow the check.
          //
            (
              if pkgs.stdenv.hostPlatform.isLinux then
                removeAttrs self.packages.${system} [
                  "beads-web"
                  "gascity"
                ]
              else
                self.packages.${system}
            );
```

- [ ] **Step 3.3: Verify eval succeeds**

```bash
nix flake check --no-build --show-trace
```

Expected: exits 0. No "infinite recursion" or "missing attribute" errors.

- [ ] **Step 3.4: Build one linux check and one darwin-only check locally**

```bash
# A linux-buildable attr (no darwin-only deps):
nix build .#checks.x86_64-linux.tmux-open-nvim --no-link
```

If currently on a Linux host, this should succeed. (On darwin, substitute `aarch64-darwin` and try `cmux`.)

Optional cross-platform smoke:

```bash
nix eval --raw .#checks.aarch64-darwin.cmux.drvPath 2>&1 | head -3
```

This should print a `.drv` path or a graceful error — NOT an "attribute missing" error.

- [ ] **Step 3.5: Format and commit**

```bash
nix fmt
git add flake.nix
git status   # confirm only flake.nix changed
git commit -m "feat(ci): build all packages via flake checks

Add self.packages.\${system} to checks so nix flake check exercises every
derivation in CI, not just formatting and linting. On linux, exclude
beads-web and gascity (their lib.fakeHash placeholders make builds
deterministically fail until deepdive B5/B6 are addressed in Chunk 3).

Coverage asymmetry: linux CI now builds ~6 attrs; darwin CI builds ~11
(the linux subset plus the darwin-only cmux, c9watch-cli, c9watch-gui).
cmux/c9watch breakage is therefore caught only on the slower darwin runner.

Fixes deepdive finding T1.
"
```

- [ ] **Step 3.6: Push and wait for CI**

```bash
git push -u origin feat/ci-builds-packages
gh run watch
```

Expected: both matrix jobs green. If a package other than `beads-web`/`gascity` fails:

- Investigate the failure log: `gh run view --log-failed`.
- If the fix is small (minutes) — apply inline, commit on this branch, re-push.
- If the fix is larger — add the package to the `removeAttrs` list with an inline comment `# Excluded: <reason>; track in Chunk 3.`, re-push, and tell the user about the new follow-up.

- [ ] **Step 3.7: Human-merge checkpoint**

STOP. Tell the user: "Branch 3 (T1) CI is green. Please merge `feat/ci-builds-packages` to main locally, push, and confirm before I start Task 4."

Wait for confirmation. If new exclusions were added, mention them so the user can decide whether to file follow-ups now.

---

## Task 4: S2 Part A — Pin `nix-repo-base` lib via lock with self-repair fallback

**Why now:** Independent of B1/T1. Closes the main `nix-repo-base`-HEAD code-execution hole before Task 5 gates the bot's auto-merge.

**Files:**
- Modify: `update-locks.sh:26-31` (replace the lib-resolution lines)
- Modify: `update-locks.sh:46-47` and `:82-83` (add explanatory comments at the `nix run nixpkgs#nix-prefetch-github` sites)

**Branch:** `fix/pin-updater-lib`

### Steps

- [ ] **Step 4.1: Create branch off updated main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git checkout main
git pull --ff-only origin main
git checkout -b fix/pin-updater-lib
```

- [ ] **Step 4.2: Confirm the lock node name and that resolution works**

```bash
nix flake metadata --json | jq -r '.locks.nodes."phillipgreenii-nix-base".locked.rev'
```

Expected: a 40-char SHA (e.g. `92dfd3ec3b628d78be28c8730b235f6872833a55`). If this prints `null` or an error, the spec assumption is wrong — stop and investigate.

- [ ] **Step 4.3: Replace the lib-resolution lines in `update-locks.sh`**

Edit `update-locks.sh:26-31`. Replace:

```bash
# Resolve which update-locks-lib.bash to source via the canonical flake resolver.
# Pass WORKSPACE_ROOT so the resolver can prefer the on-disk sibling when present.
export WORKSPACE_ROOT
UL_LIB_DIR="${UL_LIB_DIR:-$(nix run "github:phillipgreenii/nix-repo-base#determine-ul-lib-dir")}"
# shellcheck disable=SC1091
source "${UL_LIB_DIR}/update-locks-lib.bash"
```

With:

```bash
# Resolve which update-locks-lib.bash to source via the canonical flake resolver.
# Pin nix-repo-base to the locked rev (closes the unpinned-HEAD code-execution
# hole that GH_TOKEN-bearing CI would otherwise expose). Fall back to unpinned
# HEAD when the lock itself is the broken artifact, preserving the self-repair
# property — see Step 4.5 and nix-repo-base's 2026-05-29 update-locks-resilience
# design doc (lines 35, 262).
NRB_REV=$(nix flake metadata --json 2>/dev/null \
  | jq -r '.locks.nodes."phillipgreenii-nix-base".locked.rev // empty')
if [ -n "$NRB_REV" ]; then
  NRB_REF="github:phillipgreenii/nix-repo-base/${NRB_REV}"
else
  echo "WARN: could not resolve nix-repo-base from flake.lock; using unpinned HEAD" >&2
  NRB_REF="github:phillipgreenii/nix-repo-base"
fi

# Pass WORKSPACE_ROOT so the resolver can prefer the on-disk sibling when present.
export WORKSPACE_ROOT
UL_LIB_DIR="${UL_LIB_DIR:-$(nix run "${NRB_REF}#determine-ul-lib-dir")}"
# shellcheck disable=SC1091
source "${UL_LIB_DIR}/update-locks-lib.bash"
```

- [ ] **Step 4.4: Add documenting comment above the `nix-prefetch-github` call in `update_tmux_plugin`**

Edit `update-locks.sh`. In `update_tmux_plugin` (currently around line 47-48, just before the `prefetch_json=$(nix run nixpkgs#nix-prefetch-github ...)` line), add a comment block:

Find:
```bash
  echo "==> Updating tmux plugin ${plugin_name}..."

  local prefetch_json
  prefetch_json=$(nix run nixpkgs#nix-prefetch-github -- --json --rev "$branch" "$owner" "$repo" 2>/dev/null)
```

Replace with:
```bash
  echo "==> Updating tmux plugin ${plugin_name}..."

  # Use `nix run nixpkgs#nix-prefetch-github` (unpinned) deliberately: the
  # updater must remain bootstrappable when this flake's devShell or
  # flake.lock is itself the artifact being repaired. See nix-repo-base's
  # 2026-05-29 update-locks-resilience design (lines 35, 262).
  local prefetch_json
  prefetch_json=$(nix run nixpkgs#nix-prefetch-github -- --json --rev "$branch" "$owner" "$repo" 2>/dev/null)
```

- [ ] **Step 4.5: Add the same comment in `update_bat_syntax`**

Edit `update-locks.sh`. In `update_bat_syntax` (currently around line 83-84), add the identical comment block:

Find:
```bash
  echo "==> Updating bat syntax ${syntax_name}..."

  local prefetch_json
  prefetch_json=$(nix run nixpkgs#nix-prefetch-github -- --json --rev "$branch" "$owner" "$repo" 2>/dev/null)
```

Replace with:
```bash
  echo "==> Updating bat syntax ${syntax_name}..."

  # Use `nix run nixpkgs#nix-prefetch-github` (unpinned) deliberately: the
  # updater must remain bootstrappable when this flake's devShell or
  # flake.lock is itself the artifact being repaired. See nix-repo-base's
  # 2026-05-29 update-locks-resilience design (lines 35, 262).
  local prefetch_json
  prefetch_json=$(nix run nixpkgs#nix-prefetch-github -- --json --rev "$branch" "$owner" "$repo" 2>/dev/null)
```

- [ ] **Step 4.6: Happy-path test — run `./update-locks.sh` end-to-end**

```bash
./update-locks.sh
```

Expected: the script runs, sourcing the lib from the pinned rev. No WARN about falling back. If anything new fails, the diff is in `update-locks.sh:26-31` — re-check the jq path and the `nix flake metadata` output format.

Verify the pinned path was used:

```bash
NRB_REV=$(nix flake metadata --json | jq -r '.locks.nodes."phillipgreenii-nix-base".locked.rev')
echo "Pinned rev: $NRB_REV"
nix eval "github:phillipgreenii/nix-repo-base/${NRB_REV}#determine-ul-lib-dir.meta.position" 2>/dev/null || echo "(eval is informational)"
```

- [ ] **Step 4.7: Sad-path test — simulate broken lock, confirm fallback fires**

```bash
mv flake.lock flake.lock.bak
./update-locks.sh 2>&1 | tee /tmp/updater-fallback.log
```

Expected output contains `WARN: could not resolve nix-repo-base from flake.lock`. The script may still fail downstream (because `flake.lock` is needed for other operations), but the FALLBACK message must appear — that's what we're testing.

Restore:

```bash
mv flake.lock.bak flake.lock
```

- [ ] **Step 4.8: Run `nix flake check --no-build` to ensure no eval regressions**

```bash
nix flake check --no-build --show-trace
```

Expected: exits 0.

- [ ] **Step 4.9: Format and commit**

```bash
nix fmt
git add update-locks.sh
git status   # confirm only update-locks.sh changed
git commit -m "fix(update-locks): pin nix-repo-base via lock with self-repair fallback

update-locks.sh:29 fetched github:phillipgreenii/nix-repo-base at default
branch HEAD (unpinned) every run, executing whatever code was at HEAD in
CI with a write-capable GH_TOKEN. Pin via the rev recorded in flake.lock
when available; fall back to unpinned HEAD with a stderr WARN when the
lock is itself the broken artifact (preserves self-repair, per
nix-repo-base/docs/superpowers/specs/2026-05-29-update-locks-resilience-design.md
lines 35, 262).

Also document inline why the two nix-prefetch-github invocations remain
unpinned-via-nix-run rather than moved to the devShell — same bootstrap
principle, deliberately rejecting the deepdive's S2 Part B recommendation.

Fixes deepdive finding S2 (Part A only; Part B intentionally not addressed).
"
```

- [ ] **Step 4.10: Push and wait for green CI**

```bash
git push -u origin fix/pin-updater-lib
gh run watch
```

Expected: both matrix jobs green. CI runs `nix flake check`; it does not run `update-locks.sh`, so the changes here are only validated by the local Steps 4.6 / 4.7.

- [ ] **Step 4.11: Human-merge checkpoint**

STOP. Tell the user: "Branch 4 (S2 Part A) CI is green. Please merge `fix/pin-updater-lib` to main locally, push, and confirm before I start Task 5."

Wait for confirmation.

---

## Task 5: S1 + T4 — Branch protection on `main` and honest PR body

**Why last:** Only safe to gate `main` once CI is green (Task 1), substantive (Task 3), and the bot itself is reproducible (Task 4).

**Files:**
- External (via `gh api`): branch protection rule on `main`
- Modify: `.github/workflows/update-flakes.yml:88-91` (PR body Verification section)

**Branch:** `chore/branch-protection`

### Steps

- [ ] **Step 5.1: Create branch off updated main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git checkout main
git pull --ff-only origin main
git checkout -b chore/branch-protection
```

- [ ] **Step 5.2: Confirm the matrix job context names from a recent successful run**

```bash
LATEST_RUN_ID=$(gh run list --workflow=ci.yml --branch=main --limit=10 \
  --json databaseId,conclusion --jq '[.[] | select(.conclusion=="success")][0].databaseId')
echo "Using run $LATEST_RUN_ID"
gh run view "$LATEST_RUN_ID" --json jobs --jq '.jobs[].name'
```

Expected output:
```
nix-checks (ubuntu-latest)
nix-checks (macos-latest)
```

If the names differ from these (e.g. include the `system` field), update the JSON in Step 5.3 to match exactly. **GitHub's matrix job naming convention only includes the matrix axes (`os`), not the `include:`-injected keys (`system`).**

- [ ] **Step 5.3: Write the protection JSON to a file**

```bash
cat > /tmp/protection.json <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "nix-checks (ubuntu-latest)",
      "nix-checks (macos-latest)"
    ]
  },
  "enforce_admins": false,
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

- [ ] **Step 5.4: Validate the JSON syntax**

```bash
jq . /tmp/protection.json
```

Expected: pretty-printed JSON with no error. If `jq` errors, fix the heredoc and re-run.

- [ ] **Step 5.5: Apply the branch protection rule**

```bash
gh api -X PUT repos/phillipgreenii/nix-overlay/branches/main/protection \
  --input /tmp/protection.json
```

Expected: a 200 response with the resulting protection config JSON. If 422, read the error message — usually a context name typo or a malformed field.

- [ ] **Step 5.6: Verify the rule via GET**

```bash
gh api repos/phillipgreenii/nix-overlay/branches/main/protection | jq .
```

Expected fields in the response:
- `required_status_checks.contexts` contains both `nix-checks (ubuntu-latest)` and `nix-checks (macos-latest)`.
- `required_status_checks.strict` is `true`.
- `enforce_admins.enabled` is `false`.
- `required_linear_history.enabled` is `true`.
- `allow_force_pushes.enabled` is `false`.
- `allow_deletions.enabled` is `false`.
- `required_pull_request_reviews` is **absent from the response** (or present with empty/null sub-fields — the API's response shape varies; what matters is the GET doesn't show enforced reviews).

If any field is wrong, edit `/tmp/protection.json` and re-run Step 5.5.

- [ ] **Step 5.7: Edit the PR body in `update-flakes.yml`**

Edit `.github/workflows/update-flakes.yml:88-91`. Replace:

```yaml
            ### Verification
            - CI checks will run automatically
            - If all checks pass, this PR will be auto-merged
            - Review the changes and close this PR if updates should not be applied
```

With:

```yaml
            ### Verification
            - Required CI checks must pass before merge (enforced by branch protection on `main`).
            - `gh pr merge --auto` will merge this PR once the required checks turn green.
            - Close this PR to abort the merge if the updates should not be applied.
```

- [ ] **Step 5.8: Run `nix flake check --no-build` to ensure nothing regressed**

```bash
nix flake check --no-build --show-trace
```

Expected: exits 0. (The workflow YAML isn't part of the flake, but a sanity check is cheap.)

- [ ] **Step 5.9: Commit the workflow change**

```bash
git add .github/workflows/update-flakes.yml
git status   # confirm only update-flakes.yml changed
git commit -m "chore(workflow): align PR body with branch-protection reality

Update the auto-PR body to describe the actual merge gate (required CI
checks via branch protection) instead of the aspirational pre-protection
text. The branch protection rule itself was applied out-of-band via
'gh api -X PUT repos/.../branches/main/protection' with both matrix job
contexts required, enforce_admins=false (preserves local-merge workflow),
and required_linear_history=true.

Fixes deepdive findings S1 and T4.
"
```

- [ ] **Step 5.10: Push and wait for CI**

```bash
git push -u origin chore/branch-protection
gh run watch
```

Expected: both matrix jobs green. (The PR-body change is docstring-only; only risk is the YAML indentation.)

- [ ] **Step 5.11: Real-world gate test (deferred)**

The true validation is the next nightly `update-flakes` run (cron: `0 11 * * *`). Either it will auto-merge after green CI (gate working), or it will stay open with a "Required statuses must pass" reason (gate working, CI was red — which is now a real signal). Manual trigger if you want to verify immediately:

```bash
gh workflow run update-flakes.yml
gh run watch
```

Capture the outcome in a follow-up note; do not block this task on it.

- [ ] **Step 5.12: Human-merge checkpoint (final)**

STOP. Tell the user: "Branch 5 (S1 + T4) CI is green. Please merge `chore/branch-protection` to main locally, push, and confirm. Chunk 1 is complete after this merge."

Wait for confirmation.

---

## Post-Chunk-1 Verification

After all 5 branches are merged, run this checklist:

- [ ] **Verify success criteria** (from spec section "Success Criteria"):

  ```bash
  # 1. CI passes
  gh run list --workflow=ci.yml --branch=main --limit=1 --json conclusion --jq '.[0].conclusion'
  # Expected: success

  # 2. Every linux package (minus exclusions) is built — check via successful run's logs
  # (Manual: check the most recent CI run's "Run nix flake check" step for build lines.)

  # 3. No master/main revs left
  grep -RE 'rev = "(master|main)"' packages/
  # Expected: no output

  # 4. update-locks.sh pinning + comments
  grep -A2 'NRB_REV=' update-locks.sh
  grep -B1 'nix run nixpkgs#nix-prefetch-github' update-locks.sh
  # Expected: NRB_REV fallback present; both nix-prefetch-github calls have the documenting comment

  # 5. Branch protection
  gh api repos/phillipgreenii/nix-overlay/branches/main/protection \
    | jq '{contexts: .required_status_checks.contexts, strict: .required_status_checks.strict, admins: .enforce_admins.enabled, linear: .required_linear_history.enabled}'
  # Expected: contexts array has both jobs; strict=true; admins=false; linear=true

  # 6. PR body honest
  grep -A3 '### Verification' .github/workflows/update-flakes.yml
  # Expected: new wording present, no "If all checks pass, this PR will be auto-merged"

  # 7. T2 fixed (CI green)
  # Covered by check 1.
  ```

- [ ] **Tell the user Chunk 1 is complete** and offer to proceed to Chunk 2 (overlay architecture inversion, A1/A2) or pause.

---

## Self-Review Notes (for the engineer executing this plan)

- **DRY** — the "create branch off updated main" step is repeated by design. Each task is independently executable; an engineer dropping into Task 4 should not need to re-read Task 1.
- **TDD spirit** — for config changes, the "failing test" is `nix flake check` failing pre-change and passing post-change; for updater changes, the "failing test" is the demonstrably-broken behavior (hand-stale a file, run updater, observe correction). For branch protection, the "test" is the gh api GET round-trip.
- **YAGNI** — no infrastructure beyond what each step requires. The `gh run watch` calls assume `gh` knows the workflow and branch; if not, fall back to `gh run list --branch=<branch> --limit=1` and watch the latest ID.
- **Frequent commits** — one commit per branch (per task). The five branches give five reversible units; intra-branch atomicity is preserved by the "commit at the end" pattern.

## Rollback Reference

| Branch | Rollback command |
|---|---|
| Task 1 (B3) | `git revert <merge-sha>` on main |
| Task 2 (B1) | `git revert <merge-sha>` on main |
| Task 3 (T1) | `git revert <merge-sha>` on main |
| Task 4 (S2) | `git revert <merge-sha>` on main |
| Task 5 protection | `gh api -X DELETE repos/phillipgreenii/nix-overlay/branches/main/protection` |
| Task 5 workflow | `git revert <merge-sha>` on main |

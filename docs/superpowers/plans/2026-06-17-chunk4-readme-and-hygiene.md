# Chunk 4: README & Hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-screen `README.md` (consumer landing page: usage snippet, package/platform matrix, pointer to ADRs), then gitignore two pieces of machine-generated state (`.update-locks/steps/` timestamp files; `.pre-commit-config.yaml` symlink into `/nix/store`), untrack them, and delete the stale `.update-locks/steps/update-c9watch` leftover from Chunk 3.

**Architecture:** Single local branch `docs/readme-and-hygiene` off `main`. Four components on one branch (README, gitignore additions, on-disk delete of stale c9watch step, mass index-untrack of step files + pre-commit symlink). Push to `origin` for human-merge. CI does not trigger on feature branches; verification is local.

**Tech Stack:** Markdown for README; `.gitignore` syntax; `git rm` / `git rm --cached` for file-tracking changes. No Nix code changes (`nix flake check` is a sanity-check, not a behavior change).

**Source spec:** `docs/superpowers/specs/2026-06-17-chunk4-readme-and-hygiene-design.md`
**Source review:** `2026-06-12-nix-overlay-deepdive.md` (findings U1, U2, U4)

## Global Constraints

These apply to every step; the implementer must internalize them before starting.

- **Work in the worktree at `/home/tcadmin/workspace/nix-overlay-chunk1`.** The sibling main checkout at `/home/tcadmin/workspace/nix-overlay` is separate; do not `cd` there. `main` is checked out in the sibling — you cannot `git checkout main` in this worktree. Branch directly off `origin/main` with `git checkout -b docs/readme-and-hygiene origin/main`.
- **No pull requests.** Never run `gh pr create` / `gh pr merge` / `gh pr` of any kind. Your job ends with `git push`; the human merges to `main` locally and pushes.
- **CI does not run on feature branches.** `.github/workflows/ci.yml` triggers only on push-to-main and PRs-against-main. Do NOT run `gh run watch` — it hangs forever. Verification is local: `nix flake check --show-trace`.
- **Run `nix flake check` WITHOUT `--no-build`** (Chunk 3 lesson: `--no-build` skips the `check-linting` derivation, masking statix errors). For Chunk 4 the only Nix touch is incidental, but the discipline matters — and you want to confirm no nightly-bot drift introduced a regression while the spec branch was being merged.
- **Vault key infra issue.** The remote builder `192.168.2.53` has been failing on derivations requiring `/run/vault-secrets/nix-signing-key.sec`. If `nix fmt` (or any other `nix` command) fails with "No such file or directory" for that path, retry with `--builders '' --max-jobs 4` to force local execution.
- **Use the Edit tool for `.gitignore` substitutions, not Write.** Use Write only for the brand-new `README.md` file.
- **Do NOT touch packages, overlays, flake.nix, update-locks.sh, or treefmt.nix.** Chunk 4 is documentation + file-tracking hygiene only.

## Preconditions

1. The spec branch `docs/chunk4-readme-and-hygiene-spec` (which also contains this plan) has been merged into `main` and pushed. The implementation branch branches from the post-merge main so the docs travel with the code.
2. Worktree exists at `/home/tcadmin/workspace/nix-overlay-chunk1`. (Existed from Chunks 1–3; reused.)
3. Post-Chunk-3 `main` HEAD includes commit `b8ee270` (`fix: use inherit (current) hash to satisfy statix W04`) or later. Verify with `git log --oneline origin/main -1` after fetch.
4. `gh` CLI is authenticated as a user with write access to `phillipgreenii/nix-overlay`.

---

## Task: Chunk 4 — README + Hygiene (single branch)

**Why one branch:** all four components are tiny, mutually independent in effect but share a single concern (consumer-facing repo cleanup) and a single CI surface. Splitting would multiply ceremony for no review benefit.

**Files:**
- Create: `README.md` (new, at repo root)
- Modify: `.gitignore` (append two new entries)
- Delete (index + on-disk): `.update-locks/steps/update-c9watch`
- Untrack (index only; leave on-disk): `.pre-commit-config.yaml`, all remaining files under `.update-locks/steps/`

**Interfaces:**
- Consumes: post-Chunk-3 state — c9watch removed from packages/overlay/apps/update-locks.sh; beads-web/gascity use `supportedPlatforms` attrset; cmux declares `platforms.darwin`; tmux plugins declare `platforms.unix`; bat-gherkin-syntax declares `platforms.unix`; yaziPlugins declare `platforms.all`.
- Produces: a `README.md` at repo root that renders cleanly on GitHub; `.gitignore` covers `.update-locks/steps/` and `.pre-commit-config.yaml`; no tracked step files remain; the pre-commit symlink is untracked (still present on-disk via devShell hook).

**Branch:** `docs/readme-and-hygiene`

### Steps

- [ ] **Step 1: Create branch off updated origin/main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git fetch origin
git checkout -b docs/readme-and-hygiene origin/main
git log --oneline origin/main -1
```

Expected: clean checkout. Last commit on `origin/main` should be at or after `b8ee270` (post-Chunk-3). If `git checkout` reports "your local changes would be overwritten", investigate — the worktree should be clean from Chunk 3's completion; do not blow it away without checking.

- [ ] **Step 2: Confirm current state matches plan assumptions**

```bash
# c9watch is gone from packages (Chunk 3 invariant)
ls packages/c9watch 2>&1 | grep -q 'No such file or directory' && echo "OK: no c9watch dir" || echo "FAIL: c9watch dir still present — Chunk 3 incomplete"

# The stale step file still exists (we will delete it)
ls .update-locks/steps/update-c9watch && echo "OK: stale step file present (will delete)" || echo "INFO: stale step file already gone — Step 5 is a no-op"

# The pre-commit symlink is still tracked
git ls-files .pre-commit-config.yaml
# Expected: prints ".pre-commit-config.yaml"

# Step files are still tracked
git ls-files .update-locks/steps/ | wc -l
# Expected: 9 (8 active + 1 stale c9watch)

# .gitignore does not yet contain the two new patterns
grep -E '^\.update-locks/steps/$|^\.pre-commit-config\.yaml$' .gitignore && echo "INFO: gitignore patterns already present" || echo "OK: patterns absent (will add)"
```

If the stale step file is already gone (e.g. someone cleaned it incidentally), Step 5's `git rm -f .update-locks/steps/update-c9watch` will fail because the file is no longer present and no longer needed. In that case skip Step 5 entirely.

- [ ] **Step 3: Create `README.md` at repo root**

Use the Write tool to create `/home/tcadmin/workspace/nix-overlay-chunk1/README.md` with the following exact contents (no leading blank line; the file starts with `# phillipgreenii-nix-overlay`).

The outer fence below uses **four** backticks (````markdown`) precisely so the inner triple-backtick `nix` fences inside the README don't close it. In the final `README.md` file, the fences are all three backticks at column 0 — no four-backtick fences. Strip the outermost four-backtick wrapper when writing.

````markdown
# phillipgreenii-nix-overlay

Third-party Nix packages absent from or outdated in nixpkgs.

## Usage

Add to your flake's `inputs`:

```nix
inputs.phillipgreenii-nix-overlay = {
  url = "github:phillipgreenii/nix-overlay";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Apply the overlay to a `pkgs` import (NixOS, home-manager, or any flake consuming nixpkgs):

```nix
pkgs = import nixpkgs {
  system = "x86_64-linux";
  overlays = [ phillipgreenii-nix-overlay.overlays.default ];
};
```

After that, `pkgs.beads-web`, `pkgs.tmuxPlugins.tmux-open-nvim`, etc. resolve normally.

## Packages

| Name | Platforms | Source |
| --- | --- | --- |
| `beads-web` | aarch64-darwin, x86_64-linux | [weselow/beads-web](https://github.com/weselow/beads-web) |
| `gascity` | aarch64-darwin, x86_64-linux | [gastownhall/gascity](https://github.com/gastownhall/gascity) |
| `bat-gherkin-syntax` | unix | [keith-hall/SublimeGherkinSyntax](https://github.com/keith-hall/SublimeGherkinSyntax) |
| `tmuxPlugins.tmux-open-nvim` | unix | [trevarj/tmux-open-nvim](https://github.com/trevarj/tmux-open-nvim) |
| `tmuxPlugins.tmux-mouse-swipe` | unix | [jaclu/tmux-mouse-swipe](https://github.com/jaclu/tmux-mouse-swipe) |
| `tmuxPlugins.tmux-nerd-font-window-name` | unix | [joshmedeski/tmux-nerd-font-window-name](https://github.com/joshmedeski/tmux-nerd-font-window-name) |
| `yaziPlugins.icons-brew` | all | (in this repo, `packages/yaziPlugins/icons-brew`) |
| `yaziPlugins.bunny` | all | (in this repo, `packages/yaziPlugins/bunny`) |
| `cmux` | darwin (aarch64-darwin verified) | [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) |

`legacyPackages.${system}.yaziPlugins` exposes the structured `{ icons-brew, bunny }` set.

## Other outputs

- `overlays.firefox-binary-wrapper` — opt-in: replaces nixpkgs' Firefox `makeWrapper` with `makeBinaryWrapper` so macOS attributes TCC permissions to `firefox` (not `bash`).
- `homeModules.install-metadata` — emits a marker file describing the overlay revision into the user's profile (consumed by personal home-manager configs).
- `apps.update-{cmux,beads-web,gascity}` — internal updater apps invoked by `update-locks.sh`.

## Update automation

`update-locks.sh` (run by `.github/workflows/update-flakes.yml` nightly) bumps package versions and hashes; the workflow opens a PR which auto-merges after CI passes on the gated `main` branch.

## ADRs

See [`docs/adr/`](docs/adr/) for the rationale behind this repo's existence and structure:

- [0000 — Use Architecture Decision Records](docs/adr/0000-use-architecture-decision-records.md)
- [0001 — Purpose of this repo](docs/adr/0001-purpose-of-this-repo.md)
````

**Critical:** the final `README.md` uses triple-backtick fences for its `nix` snippets (at column 0). Those are NOT nested in any outer fence — this is a top-level `.md` file rendered directly by GitHub. The four-backtick wrapper above is only present in this plan so the plan renders correctly when read.

The `cmux` platforms cell reads "darwin (aarch64-darwin verified)" because the package declares `meta.platforms = lib.platforms.darwin` (both aarch64-darwin and x86_64-darwin) but only the aarch64-darwin DMG hash has been verified — being honest about the gap without overclaiming.

- [ ] **Step 4: Append two patterns to `.gitignore`**

Use the Edit tool. Append the following block to `/home/tcadmin/workspace/nix-overlay-chunk1/.gitignore` (the current last line is `.claude/worktrees/`; add a blank line, then the new block):

old_string (the current tail of the file):
```
# Claude Code per-session worktrees (runtime state, created by EnterWorktree)
.claude/worktrees/
```

new_string:
```
# Claude Code per-session worktrees (runtime state, created by EnterWorktree)
.claude/worktrees/

# Machine-local state — not committed.
# update-locks step files are timestamp markers; one per machine.
.update-locks/steps/

# pre-commit-config.yaml is a symlink into /nix/store regenerated by the
# devShell's pre-commit hook setup. Different store paths on different
# machines.
.pre-commit-config.yaml
```

Verify:

```bash
tail -10 .gitignore
grep -nE '^\.update-locks/steps/$|^\.pre-commit-config\.yaml$' .gitignore
```

Expected: both patterns present, each on its own line, no leading slash, `.update-locks/steps/` has trailing slash (directory match).

- [ ] **Step 5: Delete the stale `update-c9watch` step file (on-disk + index)**

**Skip this step** if Step 2 reported "stale step file already gone".

```bash
git rm -f .update-locks/steps/update-c9watch
```

`git rm -f` removes the file from both the index and the working tree. After this, `ls .update-locks/steps/update-c9watch` returns "No such file or directory" and `git status` shows a staged deletion.

**Ordering matters:** this MUST happen before Step 6's mass `git rm --cached`. If Step 6 ran first, `update-c9watch` would be untracked (still on-disk), and `git rm -f` on an untracked-but-present file fails ("did not match any files").

- [ ] **Step 6: Untrack `.pre-commit-config.yaml` (index only; leave on-disk symlink)**

```bash
git rm --cached .pre-commit-config.yaml
```

`--cached` removes from the index only; the on-disk symlink to `/nix/store/8sggy.../pre-commit-config.json` is preserved (it gets regenerated by the devShell hook on next entry anyway). Combined with Step 4's gitignore, the symlink becomes untracked + ignored.

Verify:

```bash
git ls-files .pre-commit-config.yaml
# Expected: empty (no longer tracked)
ls -la .pre-commit-config.yaml
# Expected: symlink still present on disk
```

- [ ] **Step 7: Untrack remaining `.update-locks/steps/` files (index only; leave on-disk)**

```bash
git rm -rf --cached .update-locks/steps/
```

`-r` recursive, `-f` force (overrides up-to-date check; needed since gitignore now matches the files), `--cached` index-only. After this, all step files remain on disk (so `ul_run_step` can still read their timestamps) but git no longer tracks them.

Verify:

```bash
git ls-files .update-locks/steps/
# Expected: empty
ls .update-locks/steps/
# Expected: 8 files present on disk (bat-gherkin-syntax, nix-flake-update,
# tmux-mouse-swipe, tmux-nerd-font-window-name, tmux-open-nvim,
# update-beads-web, update-cmux, update-gascity)
```

- [ ] **Step 8: Run `nix flake check` to confirm no regression**

```bash
nix flake check --show-trace
# If vault key error: nix flake check --show-trace --builders '' --max-jobs 4
```

Expected: `all checks passed!`. The README + gitignore changes are not Nix-evaluated, so this is a sanity-check that no nightly-bot drift broke something during the spec-branch merge interval. **Run WITHOUT `--no-build`** to catch statix issues (Chunk 3 lesson).

- [ ] **Step 9: Inspect `git status` and the staged diff**

```bash
git status
git diff --cached --stat
git diff --cached .gitignore
```

Expected `git status` shows:
- New file (staged): `README.md`
- Modified (staged): `.gitignore`
- Deleted (staged): `.pre-commit-config.yaml`
- Deleted (staged): `.update-locks/steps/update-c9watch` (if Step 5 ran)
- Deleted (staged): the 8 remaining `.update-locks/steps/*` files

`git diff --cached --stat` should show 11 or 12 files (10 deletes + README + .gitignore; or 10 deletes + README + .gitignore if Step 5 was skipped, since the c9watch one would have already been off-disk and untracked separately by Step 7 — though the spec assumes it's present).

If the count is wrong, investigate before committing.

- [ ] **Step 10: Format and commit**

```bash
# README is plain markdown; treefmt may or may not touch it depending on
# treefmt.nix config. Run `nix fmt` regardless to catch any other staged
# file that needs formatting (defensive — shouldn't apply here).
nix fmt  # if vault key error: nix fmt --builders '' --max-jobs 4

git add README.md .gitignore  # add the modifications (deletes already staged by git rm)
git status
git commit -m "$(cat <<'EOF'
docs: add consumer README; gitignore machine-local state

README.md:
- One-screen consumer landing page at repo root.
- Usage snippet (flake input with `follows = nixpkgs;` + overlay
  application).
- Package matrix with honest meta.platforms claims per package
  (post-Chunk-3 state).
- Pointers to apps, overlays, homeModules, and ADRs.

.gitignore:
- .update-locks/steps/ — timestamp marker files written by ul_run_step;
  machine-local state (deepdive U2). The next update-locks.sh run will
  recreate them locally but won't generate misleading "update X" commits
  that touched only the step file.
- .pre-commit-config.yaml — symlink into /nix/store regenerated by the
  devShell hook (deepdive U4). Dangled on every fresh clone before.

Untracked:
- .pre-commit-config.yaml (symlink stays on disk; devShell regenerates).
- All .update-locks/steps/* files (stay on disk for ul_run_step).
- Deleted .update-locks/steps/update-c9watch outright (stale leftover
  from Chunk 3 c9watch removal).

Fixes deepdive findings U1, U2, U4.
EOF
)"
```

If `nix fmt` reflows or touches anything, re-`git add` and recommit. If it errors on the vault key path, retry with `--builders '' --max-jobs 4`.

- [ ] **Step 11: Push the branch**

```bash
git push -u origin docs/readme-and-hygiene
```

Do NOT run `gh run watch`. Do NOT open a PR. Do NOT run `gh pr create` / `gh pr merge`.

- [ ] **Step 12: Report and stop — wait for human merge**

Report status DONE. The human will:
1. Visually inspect the rendered README on GitHub (`https://github.com/phillipgreenii/nix-overlay/blob/docs/readme-and-hygiene/README.md`) to confirm tables, code fences, and links render correctly.
2. Fast-forward `main` to this branch locally and push, triggering CI on the merge.

**STOP after push.** Do not poll, do not re-verify after merge, do not start Chunk 5 — wait for the human to confirm Chunk 4 is merged and direct the next move.

---

## Post-Chunk-4 Verification

After the branch is merged to `main`, run this checklist:

- [ ] **Verify success criteria from the spec**

```bash
# 1. README exists at repo root
ls README.md
# Expected: README.md present

# 2. .gitignore includes both new patterns
grep -nE '^\.update-locks/steps/$|^\.pre-commit-config\.yaml$' .gitignore
# Expected: both patterns matched, on separate lines

# 3. Pre-commit symlink no longer tracked
git ls-files .pre-commit-config.yaml
# Expected: empty

# 4. No step files tracked
git ls-files .update-locks/steps/
# Expected: empty

# 5. Stale c9watch step file gone from disk
ls .update-locks/steps/update-c9watch 2>&1 | grep -q 'No such file' && echo "OK" || echo "FAIL: still present"

# 6. Pre-commit symlink still present on disk
ls -la .pre-commit-config.yaml | grep -q '^l' && echo "OK: still a symlink" || echo "FAIL"

# 7. Synthetic ul-step write doesn't surface in git status
date +%s > .update-locks/steps/bat-gherkin-syntax
git status .update-locks/steps/
# Expected: empty (gitignore active)
# Restore: git checkout HEAD -- .update-locks/steps/ 2>/dev/null || true
#   (actually, since the dir is untracked-from-index, just revert manually)
#   For safety, just leave the timestamp updated — ul_run_step would have
#   updated it on next run anyway.

# 8. nix flake check still passes
nix flake check --show-trace
# Expected: all checks passed!

# 9. CI on main green
gh run list --branch=main --limit=1 --json conclusion --jq '.[0].conclusion'
# Expected: success

# 10. README renders correctly on GitHub
# Manual check: open https://github.com/phillipgreenii/nix-overlay
# Expected: README displayed under file listing, tables/code/links render
```

- [ ] **Tell the user Chunk 4 is complete** and offer to proceed to Chunk 5 (nvfetcher / updater modernization, per deepdive M1) or pause.

---

## Rollback Reference

| Component | Rollback |
|---|---|
| README | `git revert <merge-sha>` — removes the README, no other impact. |
| .gitignore patterns | `git revert <merge-sha>` — restores tracking eligibility (does NOT re-add files; they were `git rm`'d separately). |
| Untrack `.pre-commit-config.yaml` | After revert, `git add .pre-commit-config.yaml` to re-stage the symlink (assuming the on-disk symlink is still present from the devShell). |
| Untrack `.update-locks/steps/*` | After revert, `git add .update-locks/steps/` to re-stage all step files. |
| Delete `update-c9watch` step file | Restore via `git show <pre-merge-sha>:.update-locks/steps/update-c9watch > .update-locks/steps/update-c9watch && git add .update-locks/steps/update-c9watch`. (Pre-Chunk-3 era only; pointless to restore in practice.) |

The four components are technically independently revertable, but in practice rolling back any of them in isolation is unlikely — the whole branch is one atomic hygiene change. `git revert` of the merge commit reverses all four at once.

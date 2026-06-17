# Chunk 4: README & Hygiene — Design

**Date:** 2026-06-17
**Source review:** [`2026-06-12-nix-overlay-deepdive.md`](../../../2026-06-12-nix-overlay-deepdive.md)
**Findings addressed:** U1 (no README), U2 (`.update-locks/steps/` not gitignored), U4 (`.pre-commit-config.yaml` symlink committed).
**Estimated effort:** ~30 min implementation + CI cycle

## Goal

The repo is consumer-facing — its purpose per `docs/adr/0001` is to be applied via `overlays.default` from downstream flakes. Today's landing page is a bare file listing. Chunk 4 adds a `README.md` short enough to fit on one screen that answers: what this is, how to consume it, what platforms each package supports, and where to find more detail. While we're at it, gitignore two pieces of machine-generated state that have been making noise (`.update-locks/steps/` time-stamp files; the `.pre-commit-config.yaml` symlink into `/nix/store`) and delete one stale leftover from Chunk 3 Task 1 (`.update-locks/steps/update-c9watch`).

## Non-Goals

- A long-form contribution guide, installation tutorials, screenshots, or anything that needs maintenance beyond the package matrix.
- Refactoring the ADRs.
- Documenting the update automation in detail (already in `docs/superpowers/specs/2026-05-29-update-locks-resilience-design.md` over in `nix-repo-base`).
- Touching `treefmt.nix` formatting rules.
- Beats automation, nvfetcher, or any Chunk 5 territory.

## Workflow

One local branch `docs/readme-and-hygiene` off `main`. Push to `origin` for human-merge. No PR opened. CI workflow only triggers on push-to-main / PR-against-main — verification is local via `nix flake check` (the README change has no Nix impact; the gitignore + symlink-untrack changes are file-tracking only).

Work in the worktree at `/home/tcadmin/workspace/nix-overlay-chunk1`. Branch directly off `origin/main` (`git checkout -b docs/readme-and-hygiene origin/main`).

## Branch Scope (single branch)

### Component 1 — `README.md`

A ~40-line file at the repo root. Sections:

1. **Title + one-line description** — match `flake.nix:2`.
2. **Usage** — a flake `inputs` snippet with the `follows = nixpkgs;` pattern, plus a one-line `outputs` snippet showing `overlays.default` applied to a pkgs import.
3. **Packages** — a small markdown table: name, platforms (per `meta.platforms` post-Chunk-3), upstream source. One row per consumer-facing package; skip the dev-shell utilities (`fix-lint`, `install-pre-commit-hooks`).
4. **Other outputs** — one-line each: `overlays.firefox-binary-wrapper`, `homeModules.install-metadata`, `apps.update-{cmux,beads-web,gascity}`.
5. **Update automation** — one sentence referencing `update-locks.sh` and the nightly `.github/workflows/update-flakes.yml`.
6. **ADRs** — link to `docs/adr/`.

Target file:

```markdown
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

See `docs/adr/` for the rationale behind this repo's existence and structure.
```

Note: the README file (`README.md`) itself is not nested — it uses normal triple-backtick fences for the `nix` snippets. The outer ```` ```markdown ```` fence shown above in this spec is purely so this spec doc can display the README's contents as code; the implementer writes only the inner contents (between the outer markdown-fence delimiters) to `README.md`. **Caveat:** GitHub-flavored Markdown closes a triple-backtick fence at the first matching triple-backtick line, so the spec doc itself renders the inner ``` as fence-closes — that's a spec-rendering quirk, not a README-rendering bug. **Verification:** the implementer must preview the rendered `README.md` on GitHub after pushing to confirm the `nix` snippets render as code blocks.

### Component 2 — `.gitignore` additions

Append to `.gitignore`:

```gitignore

# Machine-local state — not committed.
# update-locks step files are timestamp markers; one per machine.
.update-locks/steps/

# pre-commit-config.yaml is a symlink into /nix/store regenerated by the
# devShell's pre-commit hook setup. Different store paths on different
# machines.
.pre-commit-config.yaml
```

Why each:
- **`.update-locks/steps/`** — these are timestamp-marker files written by `ul_run_step` to remember when each updater last ran. Per-machine state. The deepdive (U2) cites commit `e74d564` as an example: "update-locks: update cmux" that touched only a timestamp file, generating a misleading commit on a no-op update.
- **`.pre-commit-config.yaml`** — currently a symlink into `/nix/store/8sggy40m44l6l64zg6lg7zk9y3gzc29f-pre-commit-config.json`. That store path doesn't exist on any other machine, so a fresh clone has a dangling symlink. The standard git-hooks.nix pattern is to gitignore it (machine-local generated state).

### Component 3 — Untrack `.pre-commit-config.yaml`

After the gitignore addition, the symlink is still tracked. Remove from the index without deleting the on-disk symlink:

```bash
git rm --cached .pre-commit-config.yaml
```

The on-disk symlink stays (regenerated by the devShell on next entry). After commit, it's untracked + gitignored.

### Component 4 — Delete the stale `update-c9watch` step file AND untrack remaining steps

**Ordering matters here:** do the on-disk delete of `update-c9watch` first, then the mass untrack of the remaining files. Otherwise the mass untrack untracks `update-c9watch` (leaving it on-disk), and the subsequent `git rm -f` would fail (file no longer in index but still on disk; `git rm -f` requires the file to be tracked).

Step 4a — delete stale c9watch step file (both on-disk AND from index):

```bash
git rm -f .update-locks/steps/update-c9watch
```

The `.update-locks/steps/update-c9watch` timestamp file is a leftover from before Chunk 3 Task 1 removed c9watch. The next `update-locks.sh` run would create new step files but won't clean up old ones; deleting now keeps the directory clean.

Step 4b — untrack the remaining step files (index-only; leave on-disk for `ul_run_step`):

After Component 2's gitignore addition, the *remaining* files in `.update-locks/steps/` (`bat-gherkin-syntax`, `nix-flake-update`, `tmux-mouse-swipe`, `tmux-nerd-font-window-name`, `tmux-open-nvim`, `update-beads-web`, `update-cmux`, `update-gascity`) are still tracked. To purge them from the index:

```bash
git rm -rf --cached .update-locks/steps/
```

This removes all of them from the index. They remain on disk (still readable by `ul_run_step` for timestamp lookup) but git no longer tracks them. The next `update-locks.sh` run will update them locally but won't trigger a git diff.

### Verification

1. `nix flake check --no-build --show-trace` exits 0. (No Nix files changed except possibly formatting.)
2. `cat README.md | wc -l` ≤ 80 (the rendered file should be close to 40 source-lines but tables expand).
3. `git ls-files .pre-commit-config.yaml` returns empty (no longer tracked).
4. `git ls-files .update-locks/steps/` returns empty (no longer tracked).
5. `ls .pre-commit-config.yaml` shows the symlink still exists on disk (devShell hook regenerated state).
6. `git status` after a synthetic `update-locks.sh` run shows no `.update-locks/steps/` diff (the gitignore + untrack worked).
7. After push and human merge: README renders correctly on GitHub (visual check — markdown tables, code fences, links all working).

### Risk / Rollback

- README is informational; no eval impact.
- Gitignore additions are universally safe.
- Untracking `.pre-commit-config.yaml`: a fresh clone now won't have the symlink until the devShell creates it. Documented as "machine-local"; if someone clones and tries to use pre-commit outside the devShell, they get a confusing "no config" error instead of a confusing "dangling symlink" error. Net win.
- Stale step file deletion: harmless (the file existed only because `update-locks.sh` previously had a c9watch step).
- Rollback: `git revert`.

---

## Cross-Cutting

### Implementer prompt hygiene
Same lessons as Chunks 1–3 (apply to the Chunk 4 implementer):
- **No PRs.** Push the branch; human merges.
- **CI doesn't trigger on feature branches.** Verification is local.
- Work in the worktree; can't `git checkout main` directly (sibling worktree state).
- Vault key infra: `nix fmt --builders '' --max-jobs 4` if remote builder errors on `/run/vault-secrets/nix-signing-key.sec`.
- **Run `nix flake check` without `--no-build` at least once** (Chunk 3 lesson: `--no-build` skips the `check-linting` derivation, masking statix errors). For Chunk 4 this is minor — only the gitignore and README change — but the discipline matters.

### Beads tracking
None. The single-branch structure is self-evident.

### Out-of-scope adjacent items intentionally NOT touched
- Chunk 1 update-locks committed-state nuance ([U2 deep-cut] commit-only-on-real-change in `ul_run_step`) — that lives in `nix-repo-base`'s ul library; out of scope here.
- ADR rewrites.
- Any package or overlay change.

## Success Criteria

After the branch is merged:
1. `README.md` exists at repo root, rendered cleanly on GitHub.
2. `.gitignore` includes `.update-locks/steps/` and `.pre-commit-config.yaml`.
3. `git ls-files .pre-commit-config.yaml .update-locks/steps/` returns empty.
4. `.update-locks/steps/update-c9watch` is gone (and any future c9watch resurrection requires explicit re-add).
5. `nix flake check` still passes; CI on main green.

## Open Questions

None pending. Decisions resolved in dialogue:
- README depth: ~40-line minimal per spec preview.
- Branch granularity: one branch for all four components.

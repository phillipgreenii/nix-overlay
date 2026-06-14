# Chunk 1: CI Safety Net — Design

**Date:** 2026-06-14
**Source review:** [`2026-06-12-nix-overlay-deepdive.md`](../../../2026-06-12-nix-overlay-deepdive.md)
**Findings addressed:** S1, S2, B1, B3, T1 (+ T4 bundled with S1)
**Estimated effort:** 2–3 hours including waits for CI between branches

## Goal

Get CI green for the first time since 2026-06-07, make CI actually exercise the package derivations, pin the time-bomb upstream sources, pin the updater's own dependencies, and require the green CI as a gate on `main` — so the `gh pr merge --auto` in the nightly workflow actually waits for checks instead of merging immediately.

## Non-Goals

- Architecture inversion of the overlay (A1/A2) → Chunk 2
- Platform-honesty fixes (B5/B6) and host-tool replacement (S4/B10) → Chunk 3
- `fix-lint` rewrite (B2) → Chunk 3
- README and gitignore hygiene (U1/U2/U4) → Chunk 4
- nvfetcher migration (M1) → Chunk 5
- Backlog items (A4, A5, A7, T3, S7, M7, M3) → Chunk 6

## Workflow

Five local branches off `main`, each pushed to `origin` for CI observation but **no PRs opened**. After each branch's CI is green, the user merges locally into `main` and pushes. Next branch is rebased off the new `main`.

All work happens in the worktree `/home/tcadmin/workspace/nix-overlay-chunk1` to keep the main checkout's unrelated untracked state untouched.

## Branch Order (Constraint-Driven)

```
B3 ──► T1 ──► B1 ──► S2 ──► S1 + T4
fix    feat   fix    fix    chore
```

- **B3 first**: nothing else can land while CI is red — required-check gating (S1) is meaningless until CI can pass.
- **T1 next**: makes CI checks substantive before we require them.
- **B1 + S2**: reproducibility fixes; order between them is interchangeable but B1 affects derivation files (smaller blast radius) while S2 affects the updater shell script.
- **S1 + T4 last**: only safe to gate `main` once the gate is meaningful (T1) and the gated artifact is trustworthy (B1 + S2). T4 is a one-line PR-body edit naturally bundled here.

## Branch 1 — `fix/yaziPlugins-flatten` (B3)

### Problem
`flake.nix:71-73` exports `packages.<system>.yaziPlugins` as a nested attrset `{ icons-brew; bunny; }`. The `packages` flake-output schema requires derivations at depth one. `nix flake check` fails: `Flake output 'packages.x86_64-linux.yaziPlugins' is not a derivation` — has failed on every push since commit `1a77932` on 2026-06-07.

### Change
`flake.nix`:
- Replace the `yaziPlugins = { ... };` attr in `packages.${system}` with two flat attrs:
  ```nix
  yaziPlugins-icons-brew = yaziPluginSet.icons-brew;
  yaziPlugins-bunny      = yaziPluginSet.bunny;
  ```
- Add a `legacyPackages.${system}` output exposing the structured set (schema-exempt), so consumers who want `pkgs.yaziPlugins.{icons-brew,bunny}` access can still get it:
  ```nix
  legacyPackages = pkgs.extend (_final: prev: {
    yaziPlugins = prev.yaziPlugins // {
      inherit (yaziPluginSet) icons-brew bunny;
    };
  });
  ```
- Leave `overlays.default` (`flake.nix:128-130`) unchanged — it already references `ownPackages.yaziPlugins`, but `ownPackages = self.packages.${system}` will no longer have a `yaziPlugins` attr after this change. **Adjustment:** in the overlay, source the plugins from `self.legacyPackages.${system}.yaziPlugins` (or from the flat package attrs), not from `ownPackages.yaziPlugins`.

### Verification
1. `nix flake check --no-build` exits 0 locally on linux.
2. Push the branch → CI matrix (linux + darwin) both go green.
3. Merge to `main` locally; the next push CI on `main` is the first green run since 2026-06-07.

### Risk / Rollback
Pure rename. If the legacyPackages addition breaks anything (unlikely), revert is `git revert`. No store-path impact for `packages.<system>.<flat-name>` consumers (they wouldn't have been working before).

---

## Branch 2 — `feat/ci-builds-packages` (T1)

### Problem
`flake.nix:48-51`'s `checks` only contains `formatting` and `linting`. The CI workflow's `nix flake check` therefore builds nothing. A bad sed (B7), invalid hash (S5), upstream artifact rename, or hdiutil change breaks a package and is only discovered by a consumer's `home-manager switch`.

### Change
`flake.nix:48-51` becomes:
```nix
checks = {
  formatting = treefmtEval.config.build.check self;
  linting    = checks-lib.linting ./.;
} // self.packages.${system};
```
(The `formatting` line is unchanged from current; only the trailing `// self.packages.${system}` is new.)

This includes trivial `writeShellScriptBin` derivations (`fix-lint`, `install-pre-commit-hooks`) — cheap to build. Linux matrix exercises linux packages; darwin matrix exercises darwin-gated packages (`cmux`, `c9watch-*`) via the existing `lib.optionalAttrs pkgs.stdenv.isDarwin` block.

### Verification
1. `nix flake check --no-build` still passes (no eval failures).
2. `nix build .#checks.x86_64-linux.beads-web` (and similar for each linux package) succeeds locally.
3. Push the branch → CI matrix builds every package on its respective platform.

### T1 Fallout
Likely surfaces broken-on-linux packages (`beads-web`, `gascity` have `lib.fakeHash` per B5/B6). **Decision: cross that bridge when we get there.** If a build fails:
- Investigate. If it's a fakeHash-only issue and the hash is readily computable, fix inline and document in the commit.
- If the fix is larger than a few minutes, narrow the checks (`removeAttrs self.packages.${system} [ "<broken-pkg>" ]`) and capture a Chunk 3 task with the specific failure.

### Risk / Rollback
The risk surface is "what if a package fails to build" — the whole point. Revert is one-line.

---

## Branch 3 — `fix/pin-source-revs` (B1)

### Problem
`packages/tmux-open-nvim/default.nix:8`, `packages/tmux-mouse-swipe/default.nix:8`, `packages/tmux-nerd-font-window-name/default.nix:8`, `packages/bat-gherkin-syntax/default.nix:6` all set `rev = "master"` or `rev = "main"` in `fetchFromGitHub`. The `sha256` matches only the branch tip *at the moment of last update*. Every upstream push silently time-bombs uncached rebuilds; cached machines silently serve stale content. Historical revs of *this* repo cannot be rebuilt.

The updaters (`update_tmux_plugin`, `update_bat_syntax` in `update-locks.sh`) already resolve the commit via `nix-prefetch-github --json` (`.rev` field on lines 51, 87) but throw it away.

### Change

**Part A — Pre-seed pinned revs into the 4 derivations.**

For each of the 4 files, resolve the current `master`/`main` head:
```bash
nix run nixpkgs#nix-prefetch-github -- --json --rev <branch> <owner> <repo> | jq -r .rev
```
Replace `rev = "master";` / `rev = "main";` with `rev = "<resolved-sha>";`. Keep `sha256` unchanged (already matches the resolved rev).

**Part B — Teach the updaters to write the rev too.**

In `update-locks.sh`, inside both `update_tmux_plugin` and `update_bat_syntax`, add (after the existing `sed` for `sha256`):
```bash
sed -i "s|rev = \"[^\"]*\";|rev = \"${new_rev}\";|" "$nix_file"
```
`new_rev` is already in scope from line 51 / 87.

### Verification
1. `nix build .#tmux-open-nvim` (and the 3 siblings) build successfully against the pinned revs.
2. Temporarily revert one of the 4 derivations to `rev = "master"` and a stale hash; run `./update-locks.sh`; confirm the diff includes both the `rev` and `sha256` changes; restore.
3. CI green.

### Risk / Rollback
Pinning revs changes the store path of these derivations (because `rev` is a fetcher input). Consumers who already had the old store paths cached are unaffected; new builds use the pinned rev. No functional change.

---

## Branch 4 — `fix/pin-updater-code` (S2)

### Problem
`update-locks.sh:29` runs `nix run "github:phillipgreenii/nix-repo-base#determine-ul-lib-dir"` — no `ref`/`rev`, so it fetches and executes whatever is at `nix-repo-base`'s default-branch HEAD at run time. Anyone with push to `nix-repo-base` (or who compromises it) gets code execution inside CI, where `GH_TOKEN` is a write-capable GitHub App token.

Similarly, lines 48 and 84 use `nix run nixpkgs#nix-prefetch-github`, which resolves via the flake registry (nixpkgs-unstable HEAD), not the locked nixpkgs.

### Change

**Part A — Pin `nix-repo-base` lib through `flake.lock`.**

`update-locks.sh:29`:
```bash
NRB_REV=$(nix flake metadata --json | jq -r '.locks.nodes."phillipgreenii-nix-base".locked.rev')
UL_LIB_DIR="${UL_LIB_DIR:-$(nix run "github:phillipgreenii/nix-repo-base/${NRB_REV}#determine-ul-lib-dir")}"
```

The script is invoked from the repo root, so `nix flake metadata` resolves to this flake. If `jq` returns null (lock-graph schema drift), the substitution becomes `nix run github:phillipgreenii/nix-repo-base/null#...` which fails loudly — fine.

**Part B — Replace `nix run nixpkgs#nix-prefetch-github` with PATH-resolved `nix-prefetch-github`.**

`flake.nix:56-60`, devShell `extraInputs`:
```nix
extraInputs = [
  pkgs.jq
  pkgs.curl
  pkgs.gnused
  pkgs.nix-prefetch-github
];
```

`update-locks.sh:48,84`:
```bash
prefetch_json=$(nix-prefetch-github --json --rev "$branch" "$owner" "$repo" 2>/dev/null)
```

The script already `ul_reexec_in_dev_shell`s (line 32), so PATH has it.

### Verification
1. `./update-locks.sh` runs to completion locally (re-execs in devShell, resolves lib from the locked rev, uses PATH-resolved nix-prefetch-github).
2. `flake.nix` still evals; devShell entry has the new input.
3. CI green.

### Risk / Rollback
Touches two files: `update-locks.sh` (replaces two `nix run ...` invocations with rev-pinned / PATH-resolved equivalents) and `flake.nix` (one new entry in `extraInputs`). No store-path-shape change for any package. Rollback is a `git revert`.

---

## Branch 5 — `chore/branch-protection` (S1 + T4)

### Problem
`.github/workflows/update-flakes.yml:101-110` calls `gh pr merge --auto --squash --delete-branch`. `--auto` only waits for *required* status checks — `main` has no required checks, so the nightly PR merges immediately regardless of CI outcome. PR #27 (2026-06-12) merged with a red CI run; commit `27420598708` on `main` shipped unreviewed binary hash bumps.

Bonus: `update-flakes.yml:88-91` PR body claims "If all checks pass, this PR will be auto-merged" — actively false today.

### Change

**Part A — Branch protection on `main` (via `gh api`).**

```bash
gh api -X PUT repos/phillipgreenii/nix-overlay/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "nix-checks (ubuntu-latest, x86_64-linux)",
      "nix-checks (macos-latest, aarch64-darwin)"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

Decisions:
- **`enforce_admins: false`** — keeps the user's local merge-to-main workflow alive. The nightly bot's PR auto-merge still works via `--auto` + required checks.
- **`required_linear_history: true`** — matches the existing squash-only pattern; avoids merge commits.
- **No required PR reviews** — would break the bot (no reviewer).
- **`restrictions: null`** — no push allowlist; admin-only bypass is enough.

Verify by `gh api repos/.../branches/main/protection | jq .`.

**Part B — Honest PR body (`.github/workflows/update-flakes.yml:88-91`).**

Replace:
```
### Verification
- CI checks will run automatically
- If all checks pass, this PR will be auto-merged
- Review the changes and close this PR if updates should not be applied
```
With:
```
### Verification
- Required CI checks must pass before merge (enforced by branch protection on `main`).
- `gh pr merge --auto` will merge this PR once the required checks turn green.
- Close this PR to abort the merge if the updates should not be applied.
```

### Verification

1. The branch protection API call succeeds; `gh api repos/.../branches/main/protection` shows the expected config.
2. To prove the gate works: push a deliberately-broken commit to a branch, open a PR with `--auto` merge enabled, observe that it does NOT merge until checks pass (or fails and stays open). **Skipped if it requires breaking main**; the nightly bot's next run is the real-world test.
3. The workflow file change is a docstring-only edit; no behavioral risk.

### Risk / Rollback
- **Branch protection misconfiguration risk**: if the contexts are misnamed (matrix job context strings are touchy), the bot's PRs never merge because they wait forever for a never-arriving check. Mitigation: capture the exact job context string from a recent successful run (`gh run view <run-id> --json jobs --jq '.jobs[].name'`) before writing the API call.
- **Rollback**: `gh api -X DELETE repos/.../branches/main/protection` removes all protection.

---

## Cross-Cutting

### CI observation between branches
Each branch is pushed to `origin`. CI completes in ~3 minutes per matrix leg. The user waits for green before merging locally and rebasing the next branch. The B3 branch is the only one where CI is expected to flip from red to green; all subsequent branches' CI should already be green when pushed (modulo their own bugs).

### Beads tracking
This repo has no beads workspace. The Chunk 1 spec lives in `docs/superpowers/specs/`. Per-branch progress is implicit in the git log. If beads tracking is wanted later, init `.beads/` against the remote Dolt and create an epic+5 tasks; out of scope for Chunk 1 itself.

### Out-of-scope adjacent items intentionally NOT touched
- **B7** (assert sed actually matched something): considered for Branch 3, deferred to Chunk 3 to keep the rev-pin diff tight.
- **U3** (laptop direct-push pattern): partially addressed by `enforce_admins=false` keeping that workflow alive. A stricter clamp belongs in a future chunk.
- **S5** (invalid-hash fallback in updaters): deepdive groups this with S3; Chunk 3.

## Success Criteria

After all 5 branches are merged:
1. `nix flake check` passes on both matrix legs in CI.
2. Every package in `self.packages.${system}` is built by CI on its applicable platform(s).
3. No derivation in this repo has `rev = "master"` or `rev = "main"` in a fixed-output fetch.
4. `update-locks.sh` resolves `nix-repo-base` lib through the locked rev; `nix-prefetch-github` comes from the devShell.
5. `main` has branch protection requiring both matrix legs to be green; admin (user) can bypass to keep local-merge workflow.
6. The nightly bot's PR body accurately describes the merge gate.

## Open Questions

None pending. Both flagged sub-decisions were resolved in dialogue:
- Branch protection: `enforce_admins=false + required_linear_history=true`.
- T1 fallout: cross when we get there.

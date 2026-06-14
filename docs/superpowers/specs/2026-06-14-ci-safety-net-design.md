# Chunk 1: CI Safety Net — Design

**Date:** 2026-06-14
**Source review:** [`2026-06-12-nix-overlay-deepdive.md`](../../../2026-06-12-nix-overlay-deepdive.md)
**Findings addressed:** S1, S2 (Part A only — see below), B1, B3, T1 (+ T4 bundled with S1; T2 resolved as side-effect of B3)
**Estimated effort:** 2–3 hours including waits for CI between branches

## Goal

Get CI green for the first time since 2026-06-07, make CI actually exercise the package derivations, pin the time-bomb upstream sources, pin the `nix-repo-base` updater lib through the lock (with a self-repair fallback), and require the green CI as a gate on `main` — so the `gh pr merge --auto` in the nightly workflow actually waits for checks instead of merging immediately.

## Non-Goals

- Architecture inversion of the overlay (A1/A2) → Chunk 2
- Platform-honesty fixes (B5/B6) and host-tool replacement (S4/B10) → Chunk 3
- `fix-lint` rewrite (B2) → Chunk 3
- README and gitignore hygiene (U1/U2/U4) → Chunk 4
- nvfetcher migration (M1) → Chunk 5
- Backlog items (A4, A5, A7, T3, S7, M7, M3) → Chunk 6
- **Moving `nix-prefetch-github` into the devShell** — explicitly *rejected*; see "S2 Part B disposition" below

## Workflow

Five local branches off `main`, each pushed to `origin` for CI observation but **no PRs opened**. After each branch's CI is green, the user merges locally into `main` and pushes. Next branch is rebased off the new `main`.

All work happens in the worktree `/home/tcadmin/workspace/nix-overlay-chunk1` to keep the main checkout's unrelated untracked state untouched.

## Branch Order (Constraint-Driven)

```
B3 ──► B1 ──► T1 ──► S2 ──► S1 + T4
fix    fix    feat   fix    chore
```

- **B3 first**: nothing else can land while CI is red — required-check gating (S1) is meaningless until CI can pass.
- **B1 second**: pin time-bomb revs *before* T1 starts building those packages in CI. Otherwise an upstream push between the local hash compute and CI build reds Branch T1 spuriously.
- **T1 third**: makes CI substantive once the time bombs are defused.
- **S2 fourth**: reproducibility of the updater itself; depends on nothing in B1/T1.
- **S1 + T4 last**: only safe to gate `main` once the gate is meaningful (T1) and the gated artifact is trustworthy (B1 + S2). T4 is a one-line PR-body edit naturally bundled here.

## Branch 1 — `fix/yaziPlugins-flatten` (B3, fixes T2 as side-effect)

### Problem
`flake.nix:71-73` exports `packages.<system>.yaziPlugins` as a nested attrset `{ icons-brew; bunny; }`. The `packages` flake-output schema requires derivations at depth one. `nix flake check` fails: `Flake output 'packages.x86_64-linux.yaziPlugins' is not a derivation` — has failed on every push since commit `1a77932` on 2026-06-07 (this is the root cause of T2).

### Change

**Required edits to `flake.nix`** (all three are mandatory; skipping any breaks eval):

1. Replace the `yaziPlugins = { ... };` attr in `packages.${system}` with two flat attrs:
   ```nix
   yaziPlugins-icons-brew = yaziPluginSet.icons-brew;
   yaziPlugins-bunny      = yaziPluginSet.bunny;
   ```

2. Add a `legacyPackages` per-system output exposing the structured set (schema-exempt; bare attrset, **not** `pkgs.extend`):
   ```nix
   legacyPackages = {
     yaziPlugins = {
       inherit (yaziPluginSet) icons-brew bunny;
     };
   };
   ```
   Consumers who want structured access write `<flake>.legacyPackages.${system}.yaziPlugins.icons-brew`.

3. **Rewire the `overlays.default` block** (`flake.nix:128-130`). Currently it does `inherit (ownPackages.yaziPlugins) icons-brew bunny;` where `ownPackages = self.packages.${system}`. After flattening, `ownPackages.yaziPlugins` no longer exists — eval fails. Source the plugins from `yaziPluginSet` directly. Since the overlay is defined outside `eachDefaultSystem` (in the `// {...}` block at `flake.nix:106-134`), `yaziPluginSet` isn't in scope there. Two options:

   - **(a) Move yaziPluginSet build into the overlay closure**: have the overlay call `final.callPackage ./packages/yaziPlugins { }` and merge only the two plugin attrs (not `mkYaziPlugin`, which would leak into consumer `pkgs.yaziPlugins`):
     ```nix
     yaziPlugins = prev.yaziPlugins // (
       let ours = final.callPackage ./packages/yaziPlugins { };
       in { inherit (ours) icons-brew bunny; }
     );
     ```
     This builds the set against the *consumer's* nixpkgs (a small partial-win for A1 in advance) and avoids the `self.packages` round-trip entirely.

   - **(b) Source from `self.legacyPackages`**: works but re-introduces the A1 inversion (consumer gets *our* nixpkgs eval of the plugins). Defer the A1 fix to Chunk 2.

   **Choose (a)** — same lines of code, fewer footguns, partial alignment with the Chunk 2 direction.

### Verification
1. `nix flake check --no-build` exits 0 locally on linux.
2. Push the branch → CI matrix (linux + darwin) both go green.
3. From a throwaway consumer flake, `pkgs.yaziPlugins.icons-brew` resolves (via overlay) and so does `<flake>.legacyPackages.${system}.yaziPlugins.icons-brew`.
4. Merge to `main` locally; the first green CI run on `main` since 2026-06-07 confirms T2 is resolved.

### Risk / Rollback
Pure rename + overlay rewire. The overlay-rewire option (a) shifts which nixpkgs evaluates the yaziPlugins set — for the icons-brew/bunny packages that's a wash since they're `stdenvNoCC` + `fetchFromGitHub`-only. Rollback is `git revert`.

---

## Branch 2 — `fix/pin-source-revs` (B1)

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
- The sed `s|rev = "[^"]*";|...|` is the same fragility class as B7 (sed-against-Nix-source). Each of the 4 files currently has exactly one `rev = ...` line, so it isn't over-greedy *today*; a `nixfmt` reflow or an attr rename could change that. Hardening this with an "assert sed matched" guard is deferred to Chunk 3 (B7 finding); accepted risk here.
- Pinning revs changes the store path of these derivations (because `rev` is a fetcher input). Consumers' previously-cached store paths are unaffected; new builds use the pinned rev. No functional change.
- Rollback is `git revert`.

---

## Branch 3 — `feat/ci-builds-packages` (T1)

### Problem
`flake.nix:48-51`'s `checks` only contains `formatting` and `linting`. The CI workflow's `nix flake check` therefore builds nothing. A bad sed, invalid hash (S5), upstream artifact rename, or hdiutil change breaks a package and is only discovered by a consumer's `home-manager switch`.

### Change

`flake.nix:48-51` becomes:
```nix
checks = {
  formatting = treefmtEval.config.build.check self;
  linting    = checks-lib.linting ./.;
}
# Linux-only exclusions: beads-web and gascity ship lib.fakeHash for linux
# (deepdive B5/B6). Until Chunk 3 makes the platform claims honest, linux CI
# must skip building them. Drop this filter once B5/B6 land.
// (
  if pkgs.stdenv.hostPlatform.isLinux
  then removeAttrs self.packages.${system} [ "beads-web" "gascity" ]
  else self.packages.${system}
);
```

The `formatting` line is unchanged from current; the rest is new.

`self.packages.${system}` reference inside `eachDefaultSystem` is the documented idiom; no infinite recursion. `writeShellScriptBin` produces a derivation, so `fix-lint` and `install-pre-commit-hooks` build cleanly (B2's complaint is about `fix-lint`'s *runtime*, not its build).

**Coverage asymmetry to acknowledge:** linux CI now builds ~6 attrs; darwin CI builds ~11 (the linux subset plus `cmux`, `c9watch-cli`, `c9watch-gui`, plus the 2 darwin-only attrs gated by `lib.optionalAttrs pkgs.stdenv.isDarwin`). cmux/c9watch breakage is therefore only caught on the darwin runner.

**Future name-collision risk:** if a future package were named `formatting` or `linting`, it would silently shadow the checks. No current package does. A one-line comment near the `//` makes this explicit.

### Verification
1. `nix flake check --no-build` still passes (no eval failures).
2. `nix build .#checks.x86_64-linux.tmux-open-nvim` (and a darwin equivalent for cmux) succeeds locally.
3. Push the branch → CI matrix builds the expected per-platform subset.

### Risk / Rollback
The risk surface is "what if a package fails to build" — the whole point. The pre-decided linux exclusion for `beads-web`/`gascity` immunizes against the known B5/B6 failures. Any *other* surprise failure should be investigated, not silently excluded; if a fix is small (minutes), do it in this branch and commit it inline; if larger, capture as a Chunk 3 task and add to the exclusion list. Rollback is a one-line revert.

---

## Branch 4 — `fix/pin-updater-lib` (S2 Part A only)

### Problem
`update-locks.sh:29` runs `nix run "github:phillipgreenii/nix-repo-base#determine-ul-lib-dir"` — no `ref`/`rev`, so it fetches and executes whatever is at `nix-repo-base`'s default-branch HEAD at run time. Anyone with push to `nix-repo-base` (or who compromises it) gets code execution inside CI, where `GH_TOKEN` is a write-capable GitHub App token. `nix-repo-base` is a personal repo with mutable HEAD — that's the real attack surface.

### S2 Part B disposition (intentionally NOT addressed)

The deepdive also recommended moving `nix run nixpkgs#nix-prefetch-github` (`update-locks.sh:48,84`) into the devShell's `extraInputs`. **We are rejecting that recommendation** because it conflicts with a prior design decision documented in `nix-repo-base/docs/superpowers/specs/2026-05-29-update-locks-resilience-design.md`:

> "scripts that bootstrap themselves should not depend on the very thing they're bootstrapping (system tools, current-system profile, etc.)" (line 262)

> "`nix-update` is fetched ad-hoc via `nix run nixpkgs#nix-update` and needs only nix, which the dev shell already provides." (line 35)

`nix-prefetch-github` from `nixpkgs` is trusted (curated channel, not a personal repo); the security gain of devShell-pinning is small. The self-repair value is large: if a botched `update-locks.sh` run breaks the devShell or the flake itself, the updater must remain runnable to fix the problem. Bundling `nix-prefetch-github` into the devShell strands the updater in exactly the case it's needed most.

`nix-agent-support/update-locks.sh` already uses `nix run nixpkgs#nix-update` (three times, unpinned, deliberate per the same principle).

**Action bundled with this branch:** add a comment at `update-locks.sh:46-47` and `:82-83` documenting the deliberate choice:
```bash
# Use `nix run nixpkgs#nix-prefetch-github` (unpinned) deliberately:
# the updater must remain bootstrappable when this flake's devShell or
# flake.lock is the artifact being repaired. See nix-repo-base's
# 2026-05-29-update-locks-resilience-design.md (lines 35, 262).
```

(Promoting this principle to a formal ADR — in `nix-repo-base` where the design lives, or vendoring a short ADR in `nix-overlay` — is captured as a Chunk 4 docs-hygiene follow-up.)

### Change

`update-locks.sh:26-31` becomes:

```bash
# Resolve nix-repo-base via the locked rev when possible.
# Fall back to unpinned HEAD if the lock is itself broken — preserves the
# self-repair property (see Part B note above).
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

Confirmed: the node name in `flake.lock` is `"phillipgreenii-nix-base"` (verified by `nix flake metadata --json | jq -r '.locks.nodes."phillipgreenii-nix-base".locked.rev'` returning a valid sha).

### Verification
1. `./update-locks.sh` runs to completion locally; `nix-repo-base` resolves to the locked rev (verify with `set -x` or by logging `$NRB_REF`).
2. Delete `flake.lock` temporarily and re-run: the WARN line appears and the script still bootstraps from unpinned HEAD — confirms the fallback path.
3. CI green (the nightly workflow uses the same script path).

### Risk / Rollback
Touches only `update-locks.sh`. Adds explanatory comments at two other locations (the `nix-prefetch-github` calls) — purely additive. Rollback is `git revert`.

---

## Branch 5 — `chore/branch-protection` (S1 + T4)

### Problem
`.github/workflows/update-flakes.yml:101-110` calls `gh pr merge --auto --squash --delete-branch`. `--auto` only waits for *required* status checks — `main` has no required checks, so the nightly PR merges immediately regardless of CI outcome. PR #27 (2026-06-12) merged with a red CI run.

Bonus: `update-flakes.yml:88-91` PR body claims "If all checks pass, this PR will be auto-merged" — actively false today.

### Change

**Part A — Branch protection on `main` (scripted via `gh api`).**

The required-check context strings are the GitHub job names. With this repo's matrix (`os: [ubuntu-latest, macos-latest]` with `include:` adding a `system` field), the rendered job names are **`nix-checks (ubuntu-latest)`** and **`nix-checks (macos-latest)`** — the `include:`-only keys do NOT appear in the context string. Re-confirm with `gh run view <recent-run-id> --json jobs --jq '.jobs[].name'` immediately before the API call.

```bash
# Validate JSON before sending — silent 422 from gh api is hard to debug.
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
jq . /tmp/protection.json   # must exit 0
gh api -X PUT repos/phillipgreenii/nix-overlay/branches/main/protection \
  --input /tmp/protection.json
gh api repos/phillipgreenii/nix-overlay/branches/main/protection | jq .
```

Decisions:
- **`enforce_admins: false`** — keeps the user's local merge-to-main workflow alive. The nightly bot's PR auto-merge still works via `--auto` + required checks.
- **`required_linear_history: true`** — matches the existing squash-only pattern; avoids merge commits.
- **`required_pull_request_reviews` key omitted entirely** — required reviews would break the bot's auto-merge (no reviewer). Omission disables; explicit `null` may misinterpret on some plan tiers.
- **`restrictions: null`** — explicitly documented by GitHub to mean "no push allowlist"; admin bypass is enough.

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

1. JSON-validity check via `jq .` exits 0 before the API call.
2. `gh api ... PUT` returns 200; `gh api ... GET | jq .` shows the expected config (including `required_pull_request_reviews` *absent* from the response).
3. Real-world gate test: the nightly bot's next run. Either it merges (checks were green) or it stays open with a "Required statuses must pass" reason (checks were red). The first nightly after this branch lands is the validation.
4. The workflow file change is docstring-only; no behavioral risk.

### Risk / Rollback
- **Misnamed contexts** = bot's PRs hang forever. Mitigated by the `gh run view` confirmation step.
- **Rollback**: `gh api -X DELETE repos/phillipgreenii/nix-overlay/branches/main/protection` removes all protection.

---

## Cross-Cutting

### CI observation between branches
Each branch is pushed to `origin`. CI completes in ~3 minutes per matrix leg. The user waits for green before merging locally and rebasing the next branch. Branch 1 (B3) is the only one where CI is expected to flip from red to green; all subsequent branches' CI should already be green when pushed (modulo their own bugs or — in Branch 3 — surfacing new B5/B6-class failures that aren't on the pre-decided exclude list).

### Beads tracking
This repo has no beads workspace. The Chunk 1 spec lives in `docs/superpowers/specs/`. Per-branch progress is implicit in the git log. If beads tracking is wanted later, init `.beads/` against the remote Dolt and create an epic + 5 tasks; out of scope for Chunk 1 itself.

### Out-of-scope adjacent items intentionally NOT touched
- **S2 Part B** (move `nix-prefetch-github` to devShell): *rejected*, see Branch 4. Promoting the bootstrap principle to a formal ADR is a Chunk 4 candidate.
- **B7** (assert sed actually matched): considered for Branch 2, deferred to Chunk 3 to keep the diff tight. Risk accepted.
- **U3** (laptop direct-push pattern): partially addressed by `enforce_admins=false` keeping that workflow alive. A stricter clamp belongs in a future chunk.
- **S5** (invalid-hash fallback in updaters): grouped with S3 in Chunk 3.
- **B5/B6** (fakeHash + dishonest meta.platforms): Branch 3 pre-excludes `beads-web`/`gascity` on linux as a temporary workaround. Permanent fix in Chunk 3 must drop the exclusion in `flake.nix`.

## Success Criteria

After all 5 branches are merged:
1. `nix flake check` passes on both matrix legs in CI.
2. Every package in `self.packages.${system}` (minus the documented linux exclusions for `beads-web`/`gascity`) is built by CI on its applicable platform(s).
3. No derivation in this repo has `rev = "master"` or `rev = "main"` in a fixed-output fetch.
4. `update-locks.sh` resolves `nix-repo-base` through the locked rev when the lock is healthy, and through unpinned HEAD with a stderr WARN when the lock is broken. The `nix-prefetch-github` invocations remain `nix run nixpkgs#...` by design.
5. `main` has branch protection requiring both matrix legs (`nix-checks (ubuntu-latest)` and `nix-checks (macos-latest)`) to be green; admin (user) can bypass to keep the local-merge workflow.
6. The nightly bot's PR body accurately describes the merge gate.
7. CI on `main` is green — first green push run since 2026-06-07. T2 resolved.

## Open Questions

None pending. The two flagged sub-decisions on S2 were resolved in dialogue (Part B rejected on bootstrap-principle grounds; Part A kept with self-repair fallback).

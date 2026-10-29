# phillipgreenii-nix-overlay — Deepdive Review (2026-06-12)

Repository: `/Users/phillipg/phillipg_mbp/phillipgreenii-nix-overlay` (github.com/phillipgreenii/nix-overlay)

## Scope & Coverage

**Read deeply (line by line):**

- `flake.nix`, `treefmt.nix`, `flake.lock` (input graph via jq), `.gitignore`, tracked-file list
- All 11 package derivations: `packages/{beads-web,gascity,cmux,tmux-open-nvim,tmux-mouse-swipe,tmux-nerd-font-window-name,bat-gherkin-syntax}/default.nix`, `packages/c9watch/{cli,gui}.nix`, `packages/yaziPlugins/{default,bunny/default,icons-brew/default}.nix`
- `overlays/firefox-binary-wrapper.nix`
- `update-locks.sh` and all four `nix/update-*.sh` + `nix/update-*.nix` wrappers
- `.github/workflows/ci.yml`, `.github/workflows/update-flakes.yml`
- `docs/adr/0001-purpose-of-this-repo.md`, `docs/adr/index.md`, `AGENTS.md`

**Skimmed:** `docs/adr/0000`, `docs/superpowers/{plans,specs}/2026-05-02-gascity-*.md`, `.beads/`, `.update-locks/steps/*`.

**Verified empirically (not just by reading):**

- Ran `nix flake show` and `nix flake check --no-build` locally — `flake check` **fails** on `packages.<system>.yaziPlugins`.
- Pulled GitHub Actions run history (`gh run list`) — CI is red on main, and PR #27 was auto-merged today (2026-06-12) **despite its CI run failing**.
- Confirmed via `gh run view 27420598708 --log-failed`: `error: Flake output 'packages.x86_64-linux.yaziPlugins' is not a derivation.`
- Evaluated `fix-lint.text` — it runs `statix fix` against a read-only `/nix/store/...-source` path.
- `git show e74d564` — an "update-locks: update cmux" commit that changes only a timestamp file.

**Not verifiable from this repo:** the contents of `phillipgreenii/nix-repo-base` lib functions (`mkChecks`, `mkPreCommitHooks`, `mkDevShell`, `mkInstallMetadata`, `update-locks-lib.bash`). Findings touching those are labeled as such.

## Executive Summary

The repo's update automation is more dangerous than useful in its current state: the nightly pipeline bumps hashes of **prebuilt third-party binaries**, never builds them, and auto-merges its own PRs even when CI fails — and CI _has been failing on every push since ~2026-06-07_ because `packages.<system>.yaziPlugins` is a nested attrset, which `nix flake check` rejects. Meanwhile, three tmux plugins and the bat syntax package pin `rev = "master"`/`"main"` in fixed-output fetches, so every upstream push silently time-bombs those builds until the next updater run. The overlay itself is wired backwards (overlay re-exports `self.packages` built against this flake's nixpkgs rather than defining packages in terms of the consumer's `final`/`prev`), `update-locks.sh` executes unpinned remote code from `nix-repo-base` HEAD — in CI, with a `contents: write` GitHub App token in the environment — and there is no README for consumers. None of these is hard to fix individually; together they mean the repo currently provides weaker reproducibility and supply-chain guarantees than it appears to.

## Security

### S1. Auto-merge proceeds with failing CI — unreviewed binary bumps land on main — **Critical**

- **Location:** `.github/workflows/update-flakes.yml:101-110`; evidence: run 27420594573 (PR CI, `failure`, 2026-06-12) and run 27420598708 (push to main of merged "chore: Update flake dependencies (#27)", `failure`).
- **Problem:** `gh pr merge --auto` only waits for _required_ status checks. The branch evidently has no required checks configured, so the nightly PR — which bumps hashes of prebuilt binaries fetched from third-party GitHub accounts — merges immediately, regardless of CI outcome. PR #27 merged today while its CI run was red.
- **Why it matters:** This is the entire safety story of the auto-update pipeline ("If all checks pass, this PR will be auto-merged" per the PR body — currently false). A compromised upstream release (e.g. `weselow/beads-web`, `minchenlee/c9watch`) would be hashed, committed, merged, and propagated to every consumer flake on the next `nix flake update`, with zero human or machine review.
- **Recommendation:** Configure branch protection on `main` with the CI job as a required status check (then `--auto` actually gates). Additionally make the update workflow itself run `nix build` on the packages it touched before opening the PR, so a bad artifact fails fast.

### S2. `update-locks.sh` executes unpinned remote code, in CI with a write token — **High**

- **Location:** `update-locks.sh:29` (`nix run "github:phillipgreenii/nix-repo-base#determine-ul-lib-dir"`), then `update-locks.sh:31` sources the resolved `update-locks-lib.bash`; invoked in CI at `.github/workflows/update-flakes.yml:46-54` with `GH_TOKEN` (a GitHub App token with `contents: write` + `pull-requests: write`) exported into the step environment.
- **Problem:** The flake reference has no `ref`/`rev`, so this fetches and executes whatever is at the default-branch HEAD of `nix-repo-base` at run time — bypassing the carefully pinned `phillipgreenii-nix-base` entry in `flake.lock` (rev `c78adf7`, flake.lock). Same again at `update-locks.sh:48,84`: `nix run nixpkgs#nix-prefetch-github` resolves via the flake registry (nixpkgs-unstable HEAD), not the locked nixpkgs.
- **Why it matters:** Anyone who can push to `nix-repo-base` (or compromise it) gets arbitrary code execution with a token that can write to this repo and merge PRs. It also makes the updater non-reproducible: today's run and tomorrow's run execute different code. It's the one place the repo's otherwise-pinned input story leaks.
- **Recommendation:** Pin: `nix run "github:phillipgreenii/nix-repo-base/<rev>#determine-ul-lib-dir"` derived from the flake.lock entry (e.g. `rev=$(nix flake metadata --json | jq -r '.locks.nodes."phillipgreenii-nix-base".locked.rev')`), or expose the resolver as an app of _this_ flake (`nix run .#determine-ul-lib-dir`) so it goes through the lock. Same for `nix-prefetch-github`: add it to the devShell (`extraInputs`) instead of `nix run nixpkgs#...`.

### S3. Update pipeline is pure TOFU — no provenance for prebuilt binaries — **Medium**

- **Location:** `nix/update-beads-web.sh:51-69`, `nix/update-gascity.sh:57-81`, `nix/update-c9watch.sh:53-77`, `nix/update-cmux.sh:53-61`.
- **Problem:** Every updater takes "whatever bytes GitHub serves for the latest release" and records the hash. There is no signature, checksum-file, or attestation verification (gascity at least likely ships goreleaser `checksums.txt`; GitHub artifact attestations exist for some projects). The hash pin only guarantees _consistency_, not _trustworthiness_ — and S1 removes the human from the loop.
- **Why it matters:** These are executables installed into PATH on your machines (`beads-web`, `gc`, `c9watch`, `cmux` — the latter an AGPL terminal app that wraps `claude`). The threat model for "auto-ingest binaries nightly from small third-party repos" deserves at least one verification step.
- **Recommendation:** Where upstream publishes `checksums.txt` (goreleaser projects like gascity almost certainly do), download and cross-check it in the updater. Consider `gh attestation verify` for repos that publish build provenance. At minimum, keep S1's required-CI gate plus an actual build/run smoke test so a swapped artifact must at least execute correctly.

### S4. Impure host-tool usage inside derivations — **Medium**

- **Location:** `packages/cmux/default.nix:15-17` (`/usr/bin/hdiutil attach/detach`), `packages/c9watch/gui.nix:37` (`/usr/bin/codesign`), `overlays/firefox-binary-wrapper.nix:21` (`/usr/bin/codesign`).
- **Problem:** Builds reach outside the Nix store into `/usr/bin`. This works only because the darwin sandbox is commonly off; with `sandbox = true` (or under Determinate Nix's stricter defaults in some configs) these builds fail. `hdiutil attach` also mounts a device during a build and there is no trap — if the `cp` fails, the mount leaks.
- **Why it matters:** Beyond sandbox-breakage, host-tool versions vary by macOS release, so outputs are not a pure function of inputs; and these packages are never built in CI (T1), so breakage will be discovered on a laptop at the worst time.
- **Recommendation:** Replace `hdiutil` with `pkgs.undmg` (handles most modern DMGs; `pkgs._7zz` covers APFS images). Replace `/usr/bin/codesign` with nixpkgs' `sigtool` (provides a `codesign` shim used throughout nixpkgs darwin bundles) or `rcodesign` for ad-hoc signing. If hdiutil must stay, add `trap '/usr/bin/hdiutil detach "$mnt" || true' EXIT`.

### S5. Invalid-hash fallback in updaters — **Medium**

- **Location:** `nix/update-cmux.sh:61`, `nix/update-beads-web.sh:67-69`, `nix/update-c9watch.sh:74-77`, `nix/update-gascity.sh:78-81`: `nix hash convert ... || echo "sha256-$RAW"`.
- **Problem:** `nix-prefetch-url` emits base32; SRI requires base64. If `nix hash convert` ever fails (older nix on a machine, PATH issue), the fallback writes `sha256-<base32>` — a syntactically plausible but invalid SRI string — into the derivation, which is then committed (and per S1, merged).
- **Recommendation:** Drop the fallback and fail hard, or use `nix-prefetch-url --type sha256` + `nix hash to-sri`, or better: `nix store prefetch-file --json <url> | jq -r .hash` which emits SRI directly.

### S6. Vestigial `id-token: write` permission — **Nit**

- **Location:** `.github/workflows/update-flakes.yml:16` ("required for FlakeHub Cache OIDC auth") — nothing in the workflow uses FlakeHub Cache.
- **Recommendation:** Remove until actually needed; least-privilege workflows.

### S7. Inconsistent action pinning — **Low**

- **Location:** `.github/workflows/ci.yml:26,32` (`determinate-nix-action@v3`, `cache-nix-action@v7` pinned by mutable tag) vs `ci.yml:23` and `update-flakes.yml:25,73` (SHA-pinned).
- **Problem:** Tag-pinned third-party actions can be retargeted; you clearly know the SHA-pinning discipline (checkout, create-pull-request) but apply it inconsistently.
- **Recommendation:** SHA-pin all actions; let Dependabot/Renovate bump them.

## Architecture

### A1. Overlay is wired backwards: packages don't come from the consumer's nixpkgs — **High**

- **Location:** `flake.nix:114-134` (`ownPackages = self.packages.${prev.stdenv.hostPlatform.system}`), with packages defined at `flake.nix:63-89` against `nixpkgs.legacyPackages.${system}` (`flake.nix:34`).
- **Problem:** The idiomatic direction is _overlay defines packages via `final.callPackage`, flake `packages` output is derived from the overlay_. Here it's inverted: the overlay re-exports derivations that were already evaluated against **this flake's locked nixpkgs** (`nixpkgs-26.05-darwin` @ `2262dac`). Consequences for consumers applying `overlays.default`:
  - Packages ignore the consumer's nixpkgs pin, config (`allowUnfree`, etc.), and any earlier overlays — `tmuxPlugins.mkTmuxPlugin`, `stdenv`, `fetchurl` all come from _your_ nixpkgs, not theirs.
  - Two nixpkgs evaluations per consumer (theirs + yours through `self.packages`), with the eval-time and store-path divergence that implies.
  - `prev.tmuxPlugins // {...}` (`flake.nix:121`) and `prev.yaziPlugins // {...}` (`flake.nix:128`) rebuild those sets from `prev`, so a consumer's _other_ overlay extending `tmuxPlugins` composes order-sensitively instead of through the fixpoint.
- **Recommendation:** Invert: `overlays.default = final: prev: { beads-web = final.callPackage ./packages/beads-web { }; tmuxPlugins = prev.tmuxPlugins // { tmux-open-nvim = final.callPackage ./packages/tmux-open-nvim { }; ... }; }` and define `packages.${system}` from `(nixpkgs.legacyPackages.${system}.extend self.overlays.default)` or via direct `callPackage`. This keeps one source of truth and makes the overlay behave the way consumers expect.

### A2. Whole-`pkgs` function signatures defeat `callPackage` — **Medium**

- **Location:** `packages/beads-web/default.nix:1`, `packages/gascity/default.nix:1`, `packages/cmux/default.nix:1`, `packages/c9watch/cli.nix:1`, `packages/c9watch/gui.nix:1`, all tmux plugins (`{ lib, pkgs }`).
- **Problem:** Taking `pkgs` wholesale means `callPackage`'s dependency injection and `.override { fetchurl = ...; }` granularity are lost; consumers can't swap a single dep, and the derivation files don't document their actual dependencies (`stdenvNoCC`, `fetchurl`, `fetchFromGitHub`, `tmuxPlugins`).
- **Recommendation:** Destructure real deps: `{ lib, stdenvNoCC, fetchurl }:` etc. This also makes the A1 inversion mechanical.

### A3. Four near-identical updater scripts + two near-identical sed functions — **Medium**

- **Location:** `nix/update-beads-web.sh`, `nix/update-gascity.sh`, `nix/update-c9watch.sh`, `nix/update-cmux.sh` (~80-90% shared structure: version grep, `releases/latest` curl, N×`nix-prefetch-url`, N×sed); `update-locks.sh:38-70` vs `update-locks.sh:74-106` (`update_tmux_plugin` and `update_bat_syntax` differ in two sed lines).
- **Problem:** Every new binary package costs a ~90-line copy-pasted script plus a `writeShellApplication` wrapper (`nix/update-*.nix`, themselves four identical files); fixes (like S5) must be applied in four places and already weren't (the `GH_TOKEN` header logic exists in the four `nix/` scripts but not in `update-locks.sh:63`'s curl).
- **Recommendation:** One parameterized updater driven by a manifest (repo, artifact URL template, list of `{platform, sed-key}`), or — better — adopt **nvfetcher** (see M1), which deletes this entire category of code.

### A4. Transitive input bloat from `nix-repo-base` — **Medium**

- **Location:** `flake.lock` — 26 nodes including `flox` (+ its own `nixpkgs_2`), `fenix` + `rust-analyzer-src` (nightly), `crane`, `bun2nix`, `blueprint`, `llm-agents`, `nix-vscode-extensions`, `nixpkgs-unstable`, `nixpkgs_3`, plus duplicated `treefmt-nix_2`, `gitignore_2`, `systems_2`. `flake.nix:11-19` only `follows` four of the base's inputs.
- **Problem:** A flake that packages a dozen binaries carries four nixpkgs revisions and a Rust toolchain pinner in its lock. Every consumer inherits this graph into their own lock; `nix flake update` churn and `flake-checker` surface area grow accordingly. The duplicated `*_2` nodes show the `follows` wiring in `nix-repo-base` itself is incomplete.
- **Recommendation:** In `nix-repo-base`, make heavy deps (`flox`, `fenix`, `crane`, `bun2nix`, ...) optional or move the dev tooling that needs them out of the `lib` consumed here; in this flake, add `follows` for any remaining shared inputs. Goal: this repo's lock should be ~6 nodes.

### A5. Top-level attribute squatting in the overlay — **Low**

- **Location:** `flake.nix:120` (`beads-web`, `bat-gherkin-syntax`, `gascity` injected at top level of pkgs), `flake.nix:133`.
- **Problem:** If nixpkgs later introduces `gascity` or `beads-web`, the overlay silently shadows it for every consumer, and there is no namespace to disambiguate.
- **Recommendation:** Either accept knowingly (document it) or also expose a namespaced set (e.g. `phillipgreenii = { beads-web = ...; }`) so consumers can choose collision-proof access.

### A6. Heavy, unversioned coupling to `nix-repo-base` lib — **Low (unverified internals)**

- **Location:** `flake.nix:37-42,53,107-110` (`mkChecks`, `mkPreCommitHooks`, `mkDevShell`, `mkInstallMetadata`), `update-locks.sh:29-33` (`update-locks-lib.bash`, `ul_*` functions).
- **Problem:** Five distinct API surfaces from a personal base repo with no version contract; a refactor there breaks this repo's eval, checks, devshell, _and_ updater in one `nix flake update` — which the nightly workflow performs and (per S1) auto-merges.
- **Recommendation:** At minimum, the required-CI gate from S1 protects against this. Longer term, tag `nix-repo-base` and reference a release ref, or vendor the small parts (the linting check is likely a few lines of statix/deadnix).

### A7. `gascity` may be a zombie package — **Low (uncertain)**

- **Location:** `packages/gascity/default.nix`, `flake.nix:65,102,120`, `update-locks.sh:120-122`.
- **Problem:** Workspace context (ADR 0043 / memory note, 2026-06-11) says Gas City was decommissioned and `gc` removed from the environment, yet the overlay still packages it, exports it by default, and re-downloads four ~20 MB artifacts on every release. If no consumer remains, this is pure nightly cost and supply-chain surface.
- **Recommendation:** Confirm no consumer flake still references `gascity`; if so, delete the package, app, updater step, and overlay entry.

## Best Practices / Code Quality

### B1. Mutable `rev = "master"`/`"main"` in fixed-output fetches — **High**

- **Location:** `packages/tmux-open-nvim/default.nix:8`, `packages/tmux-mouse-swipe/default.nix:8`, `packages/tmux-nerd-font-window-name/default.nix:8`, `packages/bat-gherkin-syntax/default.nix:6`.
- **Problem:** `fetchFromGitHub` with a branch name downloads `archive/<branch>.tar.gz`. The pinned `sha256` matches only the branch tip _at update time_. The moment upstream pushes, every uncached rebuild fails with a hash mismatch (or, more insidiously, keeps serving the stale cached store path on machines that have it, so different machines see different content for the "same" derivation). Historical revs of this repo can never be rebuilt. The updaters _already have the resolved commit_ — `nix-prefetch-github --json` returns `.rev` (`update-locks.sh:48-52`) — and throw it away; the sed at `update-locks.sh:68-69` updates only `version` and `sha256`, leaving `rev = "master"` in place.
- **Recommendation:** Store the commit: change derivations to `rev = "<sha>";` and add one sed line to `update_tmux_plugin`/`update_bat_syntax`: `sed -i "s|rev = \"[^\"]*\";|rev = \"${new_rev}\";|" "$nix_file"`. The `unstable-<date>` version convention can stay.

### B2. `fix-lint` is broken: `statix fix` against the read-only store — **High (broken tool), Medium impact**

- **Location:** `flake.nix:75-77`. Verified: `nix eval .#packages.aarch64-darwin.fix-lint.text` → `statix fix /nix/store/...-source`.
- **Problem:** `${./.}` interpolates the flake source _copied into the store_; `statix fix` cannot write there, so the tool either errors or no-ops. It also means the whole repo is a build input of this trivial script (any file change rebuilds it).
- **Recommendation:** `pkgs.writeShellScriptBin "fix-lint" ''exec ${lib.getExe pkgs.statix} fix "''${1:-.}"''` — operate on the working directory at run time, not an embedded store path.

### B3. `packages.<system>.yaziPlugins` is not a derivation — breaks `nix flake check` — **High** (see T2 for CI impact)

- **Location:** `flake.nix:71-73`. Verified locally (`error: flake attribute 'packages.aarch64-darwin.yaziPlugins' is not a derivation`) and in CI logs.
- **Problem:** The `packages` flake output schema requires derivations at depth one. `nix flake show` silently drops the attrset for the current system; `nix flake check` hard-fails.
- **Recommendation:** Flatten into `yaziPlugins-icons-brew` / `yaziPlugins-bunny` under `packages`, and keep the structured set in `legacyPackages.${system}.yaziPlugins` (schema-exempt) and in the overlay.

### B4. `mkYaziPlugin` reimplements nixpkgs — **Medium**

- **Location:** `packages/yaziPlugins/default.nix:8-33`.
- **Problem:** nixpkgs ships `pkgs.yaziPlugins.mkYaziPlugin` (validates plugin layout, sets `passthru`, handles `main.lua` checks). The local clone copies the whole repo (`cp -r . $out` — README, LICENSE, screenshots and all) with none of the validation, and is one more API to maintain.
- **Recommendation:** `pkgs.yaziPlugins.mkYaziPlugin { pname = "bunny.yazi"; ... }` directly in `bunny/default.nix` / `icons-brew/default.nix`; delete the local builder. (If the pinned 26.05 channel's version lacks it, that's worth a comment; it has existed since 24.11-era.)

### B5. Eval-time `throw` + dishonest `meta.platforms` — **Medium**

- **Location:** `packages/beads-web/default.nix:13,28-29,45` (`platforms.unix` claimed; only 3 hash entries, 2 of which are `lib.fakeHash` at lines 17-18; `throw` for any other system); same pattern `packages/gascity/default.nix:14,19-21,47-52`; `packages/c9watch/{cli,gui}.nix:11`.
- **Problem:** Three distinct lies/bombs: (1) `meta.platforms = platforms.unix` advertises e.g. `aarch64-linux`, where forcing the derivation **throws** at eval time — so `nix flake check`/`show --all-systems`, or any consumer on aarch64-linux who so much as evaluates `pkgs.beads-web`, gets an eval error instead of a clean "not supported" message; (2) `x86_64-darwin`/`x86_64-linux` are claimed supported but have `fakeHash`, so builds fail with a confusing hash mismatch; (3) `eachDefaultSystem` still exports `packages.aarch64-linux.beads-web`, so the bomb is in your own outputs.
- **Recommendation:** Make `meta.platforms` equal the set of platforms with _real_ hashes; replace the `or (throw ...)` on the platform map with that meta gating (the standard `meta.platforms` mechanism produces a proper "package not available on this platform" error). For fakeHash placeholders, either obtain real hashes (the updaters already download those artifacts — see B6) or drop the platform entirely.

### B6. Updaters download artifacts whose hashes they then can't write — **Medium**

- **Location:** `nix/update-beads-web.sh:56-65` downloads darwin-x64 and linux-x64 and computes SRI hashes (lines 68-69), but the seds at lines 74-75 match only _quoted_ values, and `packages/beads-web/default.nix:17-18` has unquoted `lib.fakeHash` — so the computed hashes are discarded every run. Same for gascity (`nix/update-gascity.sh:62-76` vs `default.nix:19-20`); the behavior is even documented as intentional at `nix/update-gascity.sh:9-12`.
- **Problem:** Every nightly run on a new release burns ~40-80 MB of downloads to compute hashes it throws away, while the package remains broken on those platforms indefinitely. The "placeholder until manually replaced" design has no path to ever being replaced — the automation actively skips it.
- **Recommendation:** Let the updater write all hashes (quote the placeholders: `darwin-x64 = "";` or seed with one real prefetch), or stop prefetching platforms you've decided not to support. Either coherent position is fine; the current one is the worst of both.

### B7. Comment-as-data and grep/sed-based Nix editing — **Medium**

- **Location:** `packages/bat-gherkin-syntax/default.nix:2` (`# last updated: unstable-...` comment is parsed/rewritten by `update-locks.sh:104`); version greps like `nix/update-cmux.sh:19` (`grep 'version = ' | head -1`); hash greps `update-locks.sh:55,91`.
- **Problem:** The derivations' formatting is load-bearing for the updaters. `nixfmt` reflowing a line, a second `version =` appearing, or an attr rename silently breaks the sed (no "did I actually change anything" assertion — sed exits 0 on zero matches). B1's stale `rev` is exactly this class of bug already shipped.
- **Recommendation:** After each sed, assert the file changed (`git diff --quiet -- "$TARGET" && fail "sed matched nothing"`), or move to structured updating: `nvfetcher` (M1) or `nix-update` + `passthru.updateScript`, which manipulate hashes through Nix itself.

### B8. `bat-gherkin-syntax` "package" is a bare fetch — **Low**

- **Location:** `packages/bat-gherkin-syntax/default.nix:3-11`; `nix flake show` reports it as `package 'source'`.
- **Problem:** No `pname`/`version`, store path named `source`, `meta` smuggled through `fetchFromGitHub` where `platforms` on a source tree is meaningless. Anything consuming it (bat config in a home-manager repo) gets an anonymous path.
- **Recommendation:** Wrap in a trivial `stdenvNoCC.mkDerivation` (or `runCommand`) with proper `pname`/`version`, or at least pass `name = "bat-gherkin-syntax-${version}"` to the fetcher.

### B9. Misc idiom nits — **Nit**

- `flake.nix:85,132`: `stdenv.isDarwin` is a deprecated alias; use `stdenv.hostPlatform.isDarwin` (used correctly in `overlays/firefox-binary-wrapper.nix:5`).
- `flake.nix:93-96`: hand-rolled `mkApp`; `program = lib.getExe drv` is the idiom, and the `drv.name` fallback would be wrong for any mkDerivation-based drv (`name` includes the version). Apps also lack `meta.description` — `nix flake show` prints "no description" eight times.
- `packages/beads-web/default.nix:39`: `meta = with pkgs.lib;` while `lib` is right there in scope (gascity uses `with lib;`); nixpkgs is moving away from `with lib;` in meta entirely.
- `packages/yaziPlugins/default.nix:35`: passing `fetchFromGitHub` explicitly through `callPlugin` is redundant — `callPackage` injects it.
- `treefmt.nix:7`: `package = pkgs.nixfmt` restates the default.
- `nix/update-*.nix`: `runtimeInputs = [ pkgs.nix ]` pins a second Nix into each app's closure; the scripts run `nix-prefetch-url` against the host daemon anyway — consider relying on ambient `nix` or accept the closure weight knowingly.
- `.github/workflows/ci.yml:44-49`: `nix fmt -- --ci` duplicates the `checks.formatting` derivation run by `nix flake check` — one of the two is redundant.

### B10. `firefox-binary-wrapper` is a silent-no-op time bomb — **Medium**

- **Location:** `overlays/firefox-binary-wrapper.nix:8-10` (`builtins.replaceStrings [ ''makeWrapper "$oldExe"'' ] ...` over `oldAttrs.buildCommand`), `:21` (`/usr/bin/codesign`, see S4).
- **Problem:** Two fragilities: (1) if nixpkgs' firefox wrapper ever stops being a `buildCommand`-style derivation, `oldAttrs.buildCommand` throws "attribute missing"; (2) worse, if the exact string `makeWrapper "$oldExe"` changes, `replaceStrings` silently substitutes nothing — the overlay keeps "working" while the actual fix (binary wrapper for TCC attribution) silently disappears, which is precisely the kind of regression you'd only notice when macOS starts attributing mic permissions to `bash` again.
- **Recommendation:** Add an assertion: `assert lib.hasInfix ''makeWrapper "$oldExe"'' oldAttrs.buildCommand;` (or `lib.assertMsg`) so an upstream change fails loudly at eval. Check whether nixpkgs has since gained a `wrapperType`/binary-wrapper option for firefox that makes the override unnecessary.

## Testing

### T1. No package is ever built — by CI, by checks, or by the updater — **High**

- **Location:** `flake.nix:48-51` (checks = `formatting` + `linting` only); `.github/workflows/ci.yml:48-49` (`nix flake check` is the only build-ish step); `.github/workflows/update-flakes.yml:46-54` (updates hashes, never builds); `update-locks.sh` (no build step before `ul_finalize`).
- **Problem:** The repo's entire reason to exist is its package derivations, and nothing exercises them. A bad sed (B7), an invalid hash (S5), an upstream artifact rename (the URL templates in `nix/update-*.sh:47-55` are guesses about upstream's naming discipline), or an hdiutil change breaks a package and nobody finds out until a consumer's `home-manager switch` fails. These are _binary fetch + install_ derivations — building all of them is seconds of CPU and a few hundred MB of bandwidth.
- **Recommendation:** Merge packages into checks: `checks = { ... } // self.packages.${system}` (after fixing B3/B5 so all exported packages are honest). CI's matrix (x86_64-linux + aarch64-darwin) then builds everything buildable. In `update-locks.sh`, have each `ul_run_step` build the package it just updated before committing.

### T2. CI has been red on every push since ~2026-06-07 and nobody/nothing reacted — **High**

- **Location:** cause at `flake.nix:71-73` (B3); evidence: failing runs 27420598708, 27395832815, 27348554216, 27333185869 (all `main`, all `failure`), introduced by commit `1a77932` (2026-06-07, yaziPlugins).
- **Problem:** Five days of red CI on main while the nightly workflow kept committing, PR-ing, and (per S1) merging. Red-CI-as-normal destroys the signal: the next _real_ breakage (bad hash, broken build) will look identical.
- **Recommendation:** Fix B3 (the actual error), then make CI required (S1), then consider a notification on workflow failure (the scheduled workflow succeeding while CI fails is exactly the blind spot).

### T3. No smoke tests / version assertions — **Medium**

- **Location:** all of `packages/` — no `passthru.tests`, no `versionCheckHook`, no `testers.testVersion`.
- **Problem:** "It built" for a fetch-and-install derivation only proves the hash matched. A linker-broken linux binary (beads-web's linux-x64 is some prebuilt blob with unknown dynamic linkage and there's no `autoPatchelfHook` — on NixOS it plausibly cannot exec at all), or a tarball layout change (`installPhase` expects `gc` at the tarball root, `packages/gascity/default.nix:39`), passes the build.
- **Recommendation:** Add `passthru.tests.version = testers.testVersion { package = ...; }` for the CLIs (`gc --version`, `beads-web --version`, `c9watch --version`) and include `passthru.tests` in checks. For linux binaries, either verify static linkage in the updater or add `autoPatchelfHook` and drop `dontFixup`.

### T4. Update workflow's verification claims are aspirational — **Medium**

- **Location:** `.github/workflows/update-flakes.yml:88-91` PR body: "CI checks will run automatically / If all checks pass, this PR will be auto-merged".
- **Problem:** As shown (S1/T2), checks run, fail, and the PR merges anyway. The documentation in the automation itself is wrong, which will mislead future-you during an incident.
- **Recommendation:** Fix S1; until then at least make the body honest.

## UX / DX

### U1. No README — consumers have nothing to go on — **High (for a repo whose purpose is consumption)**

- **Location:** repo root (tracked files contain no `README.md`; `git ls-files` verified). The only consumption docs are buried in `docs/adr/0001-purpose-of-this-repo.md`.
- **Problem:** ADR-0001 says "Downstream repos consume via flake input and `overlays.default`", but there is no example input snippet, no list of provided packages, no statement of which platforms each supports (which, per B5, is currently genuinely confusing), no mention of `overlays.firefox-binary-wrapper` or `homeModules.install-metadata` at all. A public GitHub repo whose landing page is a bare file listing.
- **Recommendation:** A ~40-line README: input snippet with `follows`, overlay usage, package/platform support matrix (generate it from the flake if you like), pointer to ADRs, and a one-line description of the update automation.

### U2. Nightly noise commits with misleading messages — **Medium**

- **Location:** `ul_run_step` behavior (external lib, unverified) + tracked state files `.update-locks/steps/*`; evidence: commit `e74d564` "update-locks: update cmux" touches only `.update-locks/steps/update-cmux` (a timestamp). The 2026-06-11 run produced nine such commits in a row (`e74d564..2c7ebb4`).
- **Problem:** ADR-0001's stated goal was to keep noise _out_ of repo histories; this repo now generates ~9 commits per run claiming package updates that didn't happen. `git log packages/cmux` vs `git log --oneline | grep cmux` disagree about reality; bisecting or auditing "when did we actually bump cmux" requires reading diffs.
- **Recommendation:** Don't track `.update-locks/steps/` in git (gitignore it; the time-based cache is per-machine state — note `--ci` mode already exists to bypass it). If the lib insists on committing, change messages for no-op runs ("update-locks: checked cmux (no change)") or amend the step driver to skip commits whose diff is only the step file.

### U3. Direct pushes to main bypass the PR/CI path entirely — **Medium**

- **Location:** workflow evidenced by git history: `update-locks: ...` commits (e.g. `7ec9341` "update nix flake.lock") sit directly on `main` (laptop runs of `./update-locks.sh` commit + push to main), while CI on those pushes fails (T2) with no consequence. `AGENTS.md:61-83` mandates agents push to remote unconditionally ("NEVER stop before pushing").
- **Problem:** Two write paths (laptop → main, nightly → PR) with different review properties; the laptop path lands hash bumps with zero gating, and the AGENTS.md mandate actively instructs agents to push even when quality gates fail ("If push fails, resolve and retry until it succeeds" — about push mechanics, but nothing conditions pushing on green checks).
- **Recommendation:** Once branch protection (S1) exists, the laptop path should go through the same PR or be exempted deliberately. Add "quality gates must pass before push" to AGENTS.md's session-completion protocol.

### U4. Committed symlink into `/nix/store` — **Low**

- **Location:** `.pre-commit-config.yaml` is tracked as a symlink (`git ls-files -s` shows mode 120000) to `/nix/store/8sggy...-pre-commit-config.json`.
- **Problem:** On any fresh clone, other machine, or CI runner, the symlink dangles until the devShell hook regenerates it; meanwhile `pre-commit` run outside the shell fails confusingly, and every hook-config change churns the committed target path.
- **Recommendation:** Gitignore it (the standard git-hooks.nix pattern) — it's machine-generated state, same category as `.direnv`.

### U5. Updater ergonomics depend on network + sibling-checkout assumptions — **Low**

- **Location:** `update-locks.sh:5-6` (`WORKSPACE_ROOT="${SCRIPT_DIR}/.."` bakes in your personal workspace layout), `:29` (cannot run offline or when `nix-repo-base` is unreachable, even though everything else needed is local).
- **Problem:** The script is the repo's primary maintenance entry point but only works inside one specific directory arrangement and with network access to resolve its own library.
- **Recommendation:** Falls out of S2's pinning fix (resolve the lib from the locked input, which is already in the store after first use); make `WORKSPACE_ROOT` optional.

### U6. No binary cache for consumers — **Low**

- **Location:** absence; `ci.yml` builds nothing (T1) and pushes nothing.
- **Problem:** Minor today (fetch+install derivations are cheap), but cmux's dmg-mounting build (S4) and any future from-source package mean consumers rebuild locally. The `id-token` permission hints a FlakeHub Cache integration was intended but never landed.
- **Recommendation:** Once T1 makes CI build packages, pushing to Cachix/FlakeHub Cache is one extra step and gives consumers instant installs.

## Modernization & Alternatives

### M1. nvfetcher — replaces ~400 lines of bespoke updater shell — **strongest fit**

All eight third-party sources fit nvfetcher's manifest model exactly: `fetch.github` + `src.github` (latest release: cmux, gascity, beads-web, c9watch) and `src.git` branch-tip tracking with _pinned resolved revs_ (tmux plugins, bat syntax — fixing B1 structurally). One `nvfetcher.toml` + generated `_sources/generated.nix` replaces `nix/update-*.{sh,nix}`, `update_tmux_plugin`, `update_bat_syntax`, and all the sed/grep fragility (B7). The nightly workflow becomes `nvfetcher && nix build ... && create PR`. Caveat: nvfetcher prefetches via `nix-prefetch`, so the TOFU point (S3) still needs the checksum/attestation step separately.

### M2. `nix-update` / `passthru.updateScript` — lighter alternative

If nvfetcher feels heavy, attach `passthru.updateScript` to each package and drive them with `nix-update --flake` — it understands version+SRI rewriting natively and eliminates the hand-rolled seds, though branch-tip packages still need the rev-pinning fix.

### M3. flake-parts — optional, but you already pay for it

`flake-parts` is _already in your lock_ (via `nix-repo-base`). Migrating from `flake-utils.eachDefaultSystem` would remove the `packages`-schema foot-gun class (B3 is harder to write under `perSystem`), give `legacyPackages` a natural home for the yaziPlugins set, and let `nix-repo-base` ship its checks/devshell/pre-commit wiring as an importable flake module instead of five ad-hoc lib functions (A6). Not urgent; do it when touching `nix-repo-base` anyway.

### M4. treefmt: add `deadnix` + `statix`

`treefmt.nix:4-11` covers nixfmt/shellcheck/shfmt only. treefmt-nix has first-class `programs.deadnix` and `programs.statix`; adding them puts lint-fixing in the same `nix fmt` entry point and lets you delete the broken `fix-lint` package (B2) outright. (The external `checks-lib.linting` may already run statix — unverified — but it doesn't _fix_.)

### M5. CI builds + `nix flake check --all-systems` eval gate

After B3/B5: add an eval-only `nix flake check --no-build --all-systems` step (catches platform-map throws on systems the matrix doesn't cover) and per-matrix `nix build .#<each package>`. `nix-fast-build` is overkill at this package count; plain `nix build` of `checks` suffices.

### M6. GitHub artifact attestation / checksums verification in the updater

`gh attestation verify <file> --repo <upstream>` for upstreams that publish provenance; goreleaser `checksums.txt` cross-check for gascity. Directly addresses S3 with ~10 lines.

### M7. Renovate/Dependabot for Actions

Covers S7 (SHA-pinned actions with automated bumps) so pinning doesn't rot.

## Prioritized Action List

1. **[Critical, 10 min]** Add branch protection on `main` with the CI job as a required status check so `gh pr merge --auto` actually gates (S1). Fix the PR-body claim (T4).
2. **[High, 15 min]** Fix `packages.<system>.yaziPlugins` — flatten to derivation-valued attrs, move the set to `legacyPackages` (B3) — and confirm CI goes green for the first time since 2026-06-07 (T2).
3. **[High, 30 min]** Pin the revs: write the resolved commit into `rev = ...` for the three tmux plugins and bat-gherkin-syntax; one extra sed line per updater function (B1).
4. **[High, 20 min]** Build what you ship: `checks = { formatting; linting; } // self.packages.${system}` and let the existing CI matrix build everything (T1); add a build step to the update workflow before PR creation.
5. **[High, 15 min]** Pin the updater's own code: resolve `determine-ul-lib-dir` and `nix-prefetch-github` through the lock, not registry/HEAD (S2).
6. **[High, ~1-2 h]** Invert the overlay: `final.callPackage ./packages/... {}` in `overlays.default`, derive `packages` from it; switch derivations to granular callPackage args (A1, A2).
7. **[Medium, 30 min]** Make platform claims honest: real hashes or removed platforms; `meta.platforms` instead of `throw`; let updaters write all hashes or stop prefetching unused ones (B5, B6).
8. **[Medium, 30 min]** Replace `/usr/bin/hdiutil` with `undmg`/`_7zz` and `/usr/bin/codesign` with `sigtool`; add the replaceStrings assertion in the firefox overlay (S4, B10).
9. **[Medium, 15 min]** Fix or delete `fix-lint` (run statix against `$PWD`, or adopt treefmt deadnix/statix and delete it) (B2, M4). Drop the invalid-hash fallback in updaters (S5).
10. **[Medium, 1 h]** Write the README (U1); gitignore `.update-locks/steps/` and `.pre-commit-config.yaml` (U2, U4).
11. **[Medium, half-day]** Adopt nvfetcher to replace the four updater scripts and two sed functions (M1, A3, B7); add checksum/attestation verification where upstream supports it (S3, M6).
12. **[Low, background]** Prune `nix-repo-base` transitive inputs (A4); add `testers.testVersion` smoke tests (T3); SHA-pin remaining actions + Renovate (S7, M7); decide gascity's fate (A7); consider flake-parts when next touching `nix-repo-base` (M3).

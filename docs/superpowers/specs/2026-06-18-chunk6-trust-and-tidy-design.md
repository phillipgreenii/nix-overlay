# Chunk 6: Trust & Tidy — Design

**Date:** 2026-06-18
**Source review:** [`2026-06-12-nix-overlay-deepdive.md`](../../../2026-06-12-nix-overlay-deepdive.md)
**Findings addressed:**
- **A5** top-level attribute squatting — hard cutover to `phillipgreenii.{...}` namespace
- **A7** `gascity` zombie package — delete entirely (already confirmed decommissioned)
- **B8** `bat-gherkin-syntax` bare-fetch — wrap as proper derivation with `pname`/`version`
- **B9** misc idiom nits — batch cleanup
- **S3/M6** provenance verification for binary upstreams — hard-fail mode
- **S6** vestigial `id-token: write` permission in `update-flakes.yml`
- **tc-0ixb2** (follow-up) missing-vs-corrupt `flake.lock` guard in `update-locks.sh`
- **tc-34rqk** (follow-up) `cmux` `meta.platforms` tighten to `aarch64-darwin` only

**Estimated effort:** ~6–8 hours implementation, of which ~2–3h is the provenance helper (S3/M6) plus per-upstream audit. Plus CI cycle after merge.

## Goal

Close the residual honesty/cleanup findings from the 2026-06-12 deepdive plus the two carried-forward follow-ups, and close the supply-chain provenance gap that Chunk 5 explicitly deferred. After Chunk 6:

- The overlay no longer squats on top-level pkgs names. Consumers explicitly access this overlay's contributions via `pkgs.phillipgreenii.{beads-web, bat-gherkin-syntax, cmux}` (or via the canonical sets for `tmuxPlugins.*` / `yaziPlugins.*`, which were already correctly nested).
- `gascity` is gone — package directory, overlay entry, `nvfetcher.toml` entries, regenerated `_sources/generated.nix`, and the bead tc-w2pr4-tracked follow-ups all reflect its removal.
- `bat-gherkin-syntax` is a proper `stdenvNoCC.mkDerivation` with `pname`, `version`, and a real `meta` — not a bare fetch result with attribute-merged meta.
- The nightly updater hard-fails when a binary upstream that previously published attestations or checksums stops doing so, or when verification mismatches. No provenance, no update.
- The macOS-only `cmux` package's `meta.platforms` is honest (`aarch64-darwin` only); `update-locks.sh` distinguishes a missing `flake.lock` (bootstrap-OK) from a corrupted one (hard-fail with operator message).
- The B9 nits batch lands: redundant `pkgs.nixfmt` package restatement in `treefmt.nix`, redundant `fetchFromGitHub` arg in `yaziPlugins/default.nix`, duplicated `nix fmt -- --ci` step in `ci.yml`, and the vestigial `id-token: write` permission (S6) in `update-flakes.yml` that produces FlakeHub 401 noise on every run. (Audit confirms `stdenv.isDarwin` deprecated alias is no longer present in `flake.nix` — `:97` and `:144` already use `hostPlatform.isDarwin`. Listed in the table below for completeness but no change needed.)

## Non-Goals

- **T3 `passthru.tests.version` smoke tests** — deferred to a later chunk (decided 2026-06-18 brainstorm). cmux's Electron `.dmg` form makes `testVersion` awkward; addressing it cleanly means deciding whether to skip cmux or fight it, and that decision is separable.
- **S7 SHA-pin remaining tag-pinned actions + M7 Renovate/Dependabot adoption** — deferred via bead tc-w2pr4. Decision: defer until the broader Renovate-vs-Dependabot-vs-manual question is settled.
- **A4 prune `nix-repo-base` transitive inputs** — requires upstream changes in `nix-repo-base` first; naturally pairs with that repo's nix-* refactor work.
- **M3 flake-parts adoption** — structural; deepdive recommended pairing with next `nix-repo-base` touch.
- **cmux APFS unpacking regression (tc-iv7vz)** — separate hotfix, not Chunk 6. Main CI being red does not block this chunk's work in a worktree; CI gates only on push-to-main.
- **Allow auto-merge repo setting (tc-21ql1)** — separate one-click GitHub setting change.
- **Reverting any prior chunk's decisions** — Chunk 4 `.update-locks/steps/` retention is intentional (commit `8847836`); Chunk 5 nvfetcher migration stands; Chunk 3 honesty pass stands.

## Workflow

Single local branch `feat/chunk6-trust-and-tidy` off post-merge `main` for implementation, after the human reviewer merges this spec+plan branch (`docs/chunk6-spec`) to main and pushes. No PR opened (CI workflow only triggers on push-to-main / PR-against-main; verification is local). Same `--ff-only` local merge pattern as Chunks 1–5.

Spec/plan work happens in the worktree at `/home/tcadmin/workspace/nix-overlay-chunk6`. Implementation worktree is recreated post-spec-merge (the chunk6 worktree may be reused or recreated).

**Single implementation branch.** Like Chunk 5, the seven scope items are coupled at the file-edit level — A5 namespace + B8 derivation + B9 nits all touch `flake.nix` and at least one package file; A7 gascity-deletion touches `nvfetcher.toml` plus regenerates `_sources/generated.nix` that other edits also depend on. Splitting risks a non-evaluating intermediate tree.

## Scope by item

### A5 — Namespace migration to `phillipgreenii.{...}` (hard cutover)

**Current overlay shape** (`flake.nix:117-146`):
```
overlays.default = final: prev: {
  beads-web         = ...;   # top-level injection
  bat-gherkin-syntax = ...;  # top-level injection
  gascity           = ...;   # top-level injection (removed by A7)
  tmuxPlugins       = prev.tmuxPlugins // { ... };  # nested — UNCHANGED
  yaziPlugins       = prev.yaziPlugins // { ... };  # nested — UNCHANGED
} // optional darwin { cmux = ...; };               # top-level injection
```

**Target shape:**
```
overlays.default = final: prev: {
  phillipgreenii = {
    beads-web          = final.callPackage ./packages/beads-web { inherit sources; };
    bat-gherkin-syntax = final.callPackage ./packages/bat-gherkin-syntax { inherit sources; };
  } // lib.optionalAttrs final.stdenv.hostPlatform.isDarwin {
    cmux = final.callPackage ./packages/cmux { inherit sources; };
  };
  tmuxPlugins = prev.tmuxPlugins // { ... };  # UNCHANGED
  yaziPlugins = prev.yaziPlugins // { ... };  # UNCHANGED
};
```

The `phillipgreenii` attribute itself is the namespace; nothing about `phillipgreenii.user.*` (the home-manager forwarder seen in nix-personal:186-192) conflicts since that's a NixOS/HM module attribute path, not a `pkgs` attribute.

**`packages.${system}` mirror** (`flake.nix:69-99`): becomes
```
packages = {
  inherit (extended.phillipgreenii) beads-web bat-gherkin-syntax;
  inherit (extended.tmuxPlugins) tmux-open-nvim tmux-mouse-swipe tmux-nerd-font-window-name;
  yaziPlugins-icons-brew = extended.yaziPlugins.icons-brew;
  yaziPlugins-bunny      = extended.yaziPlugins.bunny;
  fix-lint              = ...;
  install-pre-commit-hooks = ...;
} // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
  inherit (extended.phillipgreenii) cmux;
};
```

The flake `packages` output names stay flat (e.g. `packages.aarch64-darwin.beads-web`) — schema requires depth-1 derivations. Only the overlay namespacing changes; `nix build .#beads-web` still works.

**Consumer impact (confirmed by grep over /home/tcadmin/workspace):**

| Consumer | File | Reference | Required change |
|---|---|---|---|
| nix-personal | `home/programs/bat/gherkin-syntax.nix:22` | `pkgs.bat-gherkin-syntax` | → `pkgs.phillipgreenii.bat-gherkin-syntax` |
| nix-personal | `home/programs/tmux/default.nix:63,90,96` | `tmux-open-nvim`, `tmux-mouse-swipe`, `tmux-nerd-font-window-name` | **UNCHANGED** — accessed via `tmuxPlugins.*` |
| nix-personal | (other files) | `pkgs.beads-web`, `pkgs.cmux` | **None found** by `pkgs.beads-web`/`pkgs.cmux` grep across nix-personal `--include="*.nix"`; no change. Implementer re-confirms before finalizing the post-merge checklist. |
| homelab/nix | (all .nix files) | `pkgs.beads-web`, `pkgs.bat-gherkin-syntax`, `pkgs.cmux`, named tmux plugin attrs | **None found** by grep audit 2026-06-18. The overlay is applied (`homelab/nix/flake.nix:104,144`) but no leaf module references these packages by attribute. No change needed in homelab. |

**Post-merge follow-up** (out of band, but spec'd here for completeness): the user updates nix-personal (one file) and any homelab references after Chunk 6 lands. Until then, those consumer flakes break on next `nix flake update`. Acceptable per the brainstorm decision.

### A7 — gascity removal

Confirmed dead in the brainstorm. Five touchpoints:

1. `nvfetcher.toml`: delete `[gascity-darwin-arm64]` and `[gascity-linux-amd64]` blocks (lines 11–19).
2. Re-run `nvfetcher` to regenerate `_sources/generated.nix` — removes the `gascity-darwin-arm64` and `gascity-linux-amd64` source entries.
3. `flake.nix:77` — remove `gascity` from `packages.${system}` `inherit (extended) ...` list.
4. `flake.nix:125` (after A5 lands, the line drops too) — remove `gascity = final.callPackage ...` from the overlay.
5. `git rm -r packages/gascity/`.

Verification: `nix flake show` reports no `gascity` attribute on any system; `nix build .#gascity` errors with attribute-missing (not throw).

### B8 — bat-gherkin-syntax proper derivation

Current (`packages/bat-gherkin-syntax/default.nix`):
```nix
{ lib, sources }:
sources.bat-gherkin-syntax.src // { meta = { platforms = lib.platforms.unix; }; }
```

Target:
```nix
{ lib, stdenvNoCC, sources }:
stdenvNoCC.mkDerivation {
  pname = "bat-gherkin-syntax";
  inherit (sources.bat-gherkin-syntax) version;
  src = sources.bat-gherkin-syntax.src;
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r . $out/
    runHook postInstall
  '';
  dontBuild = true;
  meta = {
    description = "Gherkin syntax for SublimeText, consumable by bat";
    homepage    = "https://github.com/keith-hall/SublimeGherkinSyntax";
    platforms   = lib.platforms.unix;
  };
}
```

Removes the bare-`source` store-path naming, gives consumers `pname`/`version` for diagnostics, and stops the "smuggled meta on a non-derivation" pattern. The `cp -r . $out/` mirrors the current effective behavior (`sources.bat-gherkin-syntax.src` IS the full repo tarball).

Consumer impact in `nix-personal/home/programs/bat/gherkin-syntax.nix:22` is `src = pkgs.bat-gherkin-syntax;` — still works after rename (the namespaced access from A5 returns a proper derivation, which decays to a store path when assigned).

### B9 + S6 — Nits batch

| Site | Change |
|---|---|
| `flake.nix:97` and `:144` | **Audited 2026-06-18: already use `pkgs.stdenv.hostPlatform.isDarwin` / `prev.stdenv.hostPlatform.isDarwin`.** Deepdive B9's `stdenv.isDarwin` alias finding was already addressed in an earlier chunk. No change in this chunk. (Implementer should still re-grep to confirm before committing the nits batch.) |
| `treefmt.nix:7` | Delete the `package = pkgs.nixfmt;` line — restates the default. |
| `packages/yaziPlugins/default.nix:35` | Drop the explicit `fetchFromGitHub` from the `callPlugin` call set; `callPackage` injects it automatically. |
| `.github/workflows/ci.yml:44-49` | Drop the explicit `nix fmt -- --ci` step. `checks.formatting` (run by `nix flake check` at line 49) already exercises the same derivation. Keeping both was dead duplication. |
| `.github/workflows/update-flakes.yml:16` (**S6**) | Delete the `id-token: write` permission line. No step uses FlakeHub Cache OIDC; the line generates `HTTP 401 Unauthorized` noise on every nix invocation. |

**Skipped from deepdive B9** (already addressed in prior chunks): `mkApp` rewrite (flake.nix has no `apps` output anymore); `with pkgs.lib;` in `meta` blocks (already `with lib;` after Chunk 2's granular-args refactor); `runtimeInputs = [ pkgs.nix ]` in `nix/update-*.nix` (those files were deleted in Chunk 5).

### tc-0ixb2 — Missing-vs-corrupt `flake.lock` guard in `update-locks.sh`

**Insertion point:** between `set -euo pipefail` (line 3) and the `NRB_REV=$(nix flake metadata ...)` call at line 32 — i.e. immediately after `WORKSPACE_ROOT` is computed and before the network-dependent lib resolution.

**Behavior:**
- `flake.lock` missing — log a one-line info message and continue. `nix flake update` (the second `ul_run_step`) will bootstrap it. This preserves the "first-run on a clean clone works" property and the existing self-repair principle in update-locks-resilience design.
- `flake.lock` present but `jq -e '.' flake.lock >/dev/null` fails (corrupt JSON) — log a hard-fail message naming the file and `exit 1`. Operator restores from git (`git checkout HEAD -- flake.lock`) rather than letting the script silently overwrite.
- `flake.lock` present and parses but lacks the `.nodes.root` invariant — same hard-fail. (jq check: `jq -e '.nodes.root' flake.lock >/dev/null`.)

**Why this matters for the resilience design:** `update-locks.sh:32-39` already self-repairs the `nix-repo-base` resolution when `flake.lock` is unresolvable (`empty` rev → unpinned HEAD). The corrupt case currently falls into that same path silently, which can hide real corruption behind a successful run. The guard separates legitimate bootstrap from genuine corruption.

### tc-34rqk — cmux `meta.platforms` tightening

Two coupled edits:

1. `packages/cmux/default.nix:33` — `platforms = platforms.darwin;` → `platforms = [ "aarch64-darwin" ];` (or `platforms = lib.platforms.aarch64-darwin;` if that attr exists; otherwise the literal list).
2. `flake.nix:97-99` — the gate `lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin { inherit (extended) cmux; }` already correctly omits cmux on Linux, but it adds cmux to *both* `aarch64-darwin` and `x86_64-darwin` outputs. After A5, this becomes `inherit (extended.phillipgreenii) cmux`. Add a system check: `lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin") { ... }`. Same gate needed in the overlay (`flake.nix:144`).

Verification: `nix flake show --all-systems` reports cmux only under `packages.aarch64-darwin.phillipgreenii.cmux` (and `packages.aarch64-darwin.cmux` from the flat mirror), not under any other system. **The nvfetcher source URL `cmux-macos.dmg` is confirmed aarch64-only by manaflow-ai's release artifact naming convention** — Electron + Apple Silicon native.

### S3/M6 — Provenance verification for binary upstreams (hard-fail)

**Scope:** binary releases only — `beads-web` (weselow), `cmux` (manaflow-ai). After A7, gascity is gone. Git-source plugins (tmux-*, bat-gherkin-syntax) are out of scope: the SHA pinned by `nvfetcher` *is* the integrity, and there's no separate provenance artifact for a git tarball.

**Available verification methods.** The helper supports three discrete methods; each upstream is **assigned exactly one** method at audit time. There is no runtime fallback chain (fallback hides regressions: an upstream that stopped publishing attestations would silently demote to checksums and we'd never notice). Methods:

- **`attestation`** — `gh attestation verify <file> --repo <upstream>`. Strongest; requires the upstream publishing build provenance.
- **`checksums`** — download `checksums.txt` from the release page, locate the line matching the artifact file name, compare against the SRI hash nvfetcher recorded (after base64↔hex conversion). Goreleaser convention.
- **`sigstore`** — fetch `<artifact>.sig` and verify with `cosign verify-blob`. Less common; only used if the upstream publishes a detached signature.

If an upstream publishes none of these, the audit-time decision is recorded explicitly (see "Per-upstream initial audit" below) and the spec's hard-fail contract applies: the helper aborts with a documented "no provenance" error rather than silently skipping. Audit re-runs whenever an upstream changes its release pipeline (signaled by a regression: the helper's chosen method stops working).

**Per-upstream initial audit** (run during plan implementation; not pre-committed in this spec):

| Upstream | First method to evaluate | If absent, evaluate next |
|---|---|---|
| weselow/beads-web | `attestation` | `checksums` |
| manaflow-ai/cmux | `attestation` | `sigstore`, then `checksums` |

**The audit is a one-time evaluation per upstream** — the implementer checks the latest release page once, picks the *single* method that's actually published, and hard-codes it in the helper's per-upstream config (e.g. `BEADS_WEB_METHOD=attestation`). The "if absent" column is the audit-time decision tree, not a runtime fallback.

If audit determines an upstream publishes *neither* attestations nor checksums, the implementer pauses **before writing the verify step** and surfaces the gap for a decision: ship the helper anyway and let the nightly bot get stuck on that upstream (the contract — fail closed), or skip the upstream from verification with an explicit "no provenance available as of 2026-06-XX" comment in the helper (preserves automation continuity at the cost of one documented gap). This is a one-time decision per upstream, not a recurring runtime check.

**Integration point:** new `ul_run_step "verify-provenance"` between the existing `nvfetcher` step and the `nix-flake-update` step in `update-locks.sh`. The step invokes a new shell helper at repo root: `verify-provenance.sh` (sibling to `update-locks.sh`). One place, not per-package — gascity-style 4-file fan-out was the deepdive A3 anti-pattern. The `nix/` directory was removed in Chunk 5; do **not** recreate it.

**Helper script contract:**

```
verify-provenance.sh <upstream-key>...
  upstream-key = nvfetcher source key (e.g. "beads-web-darwin-arm64")

For each key:
  1. Read _sources/generated.nix to get the artifact URL and recorded hash.
  2. Look up the per-upstream verification method (table, hardcoded in the script).
  3. Download the artifact + provenance side-channel (attestation or checksums.txt).
  4. Verify per method:
     - attestation: `gh attestation verify <file> --repo <owner/repo>`
     - checksums: locate filename line in checksums.txt, compare hashes
  5. Exit non-zero on any failure; print which upstream/key/method/reason.

Determines which keys to verify by reading the git diff of _sources/generated.nix
since HEAD~1 — only re-verifies what nvfetcher actually changed in this run.
```

If verification fails, `ul_run_step` exits non-zero, which fails `update-locks.sh`, which fails the workflow's `Run update-locks.sh` step, which prevents the `Create Pull Request` step from firing. **No PR opens on bad provenance.** The next nightly retries from clean state (the corrupted `_sources/generated.nix` change is uncommitted — it lives only in the workflow runner's checkout).

**Caveat — git state on partial failure:** because `ul_run_step` commits each step as it goes, the `nvfetcher` step's source-delta commit may already exist when `verify-provenance` fails. Two options:
- **(a)** verify-provenance rolls back the nvfetcher commit with `git reset --hard HEAD~1` before exiting. Simple, safe on the workflow runner (ephemeral checkout). Risk: on a laptop run, the developer loses any uncommitted other-file edits — mitigation: assert clean working tree before starting (`ul_setup` likely already does).
- **(b)** restructure: do verification BEFORE nvfetcher commits. Requires either driving nvfetcher in two phases (compute, then write) — not supported — or pre-downloading what nvfetcher would download. Duplicate-download overhead.

Spec choice: **(a)** with a `git status --porcelain` clean assertion at the top of `update-locks.sh` (probably already enforced by `ul_setup`; verify in plan).

## Worktree, branches, ordering

| Branch | Off | Lifetime | Contents |
|---|---|---|---|
| `docs/chunk6-spec` (this branch) | `origin/main` (post-Chunk-5) | until human merge of spec+plan | this spec doc, then plan doc, then commit |
| `feat/chunk6-trust-and-tidy` | `origin/main` (post-spec-merge) | until human merge of implementation | the actual code changes |

Worktree for implementation: `/home/tcadmin/workspace/nix-overlay-chunk6` (re-checkout the implementation branch after spec merges; the docs worktree may be removed first).

## Verification (local; CI doesn't gate feature branches)

Order of local verification after implementation:

1. `nix flake show` — no `gascity` anywhere; `phillipgreenii.{...}` present; `cmux` only under `aarch64-darwin`.
2. `nix flake check --show-trace -L` (no `--no-build`) — passes all derivations on local system. Confirms B8 wrap produces a real derivation, A5 names resolve, B9 nits don't break eval.
3. `nix flake check --all-systems --show-trace -L` (eval-only across all four systems) — catches cross-system regressions of the cmux gate (tc-34rqk) and the A5 namespace optionalAttrs structure that step 2 cannot see from the local system. Eval errors only; no build.
4. `nix build .#beads-web .#bat-gherkin-syntax` (and `.#cmux` on aarch64-darwin) — each produces a store path with the expected `pname` in its name. (cmux APFS regression tc-iv7vz means cmux may fail to build — that's expected, separately tracked, doesn't block Chunk 6 merging.)
5. **Consumer eval smoke test:** in the worktree, run `nix eval --impure --expr 'let f = builtins.getFlake "git+file:///home/tcadmin/workspace/nix-overlay-chunk6"; pkgs = (import f.inputs.nixpkgs { system = builtins.currentSystem; }).extend f.outputs.overlays.default; in pkgs.phillipgreenii.bat-gherkin-syntax.pname'` — must return `"bat-gherkin-syntax"`. Exercises the renamed access path the way nix-personal will after its post-merge update.
6. `./update-locks.sh` (local, not `--ci`) — runs nvfetcher, then provenance verify against current sources. Should be a no-op or a clean update with verified provenance. Confirms the new step works.
7. **Provenance hard-fail test:** temporarily edit one entry in `_sources/generated.nix` to a wrong hash, re-run `./update-locks.sh` — must exit non-zero from the verify step.
8. **Rollback verification (paired with step 7):** after the failed run, `git status --porcelain` must report a clean tree — the nvfetcher commit is gone, working tree restored. If status shows lingering `_sources/generated.nix` changes, the `git reset --hard HEAD~1` rollback strategy is broken.
9. **Corrupt-lockfile test:** `echo "{" > flake.lock; ./update-locks.sh` — must exit non-zero with the tc-0ixb2 guard's message. Restore `flake.lock` from git after.
10. **Missing-lockfile test:** `mv flake.lock flake.lock.bak; ./update-locks.sh` — must complete (bootstrap path regenerates the lock). Restore the original after to leave the tree clean.

Post-merge to main, CI matrix runs (`ubuntu-latest`, `macos-latest`) and re-validates everything except the cmux build (blocked by tc-iv7vz APFS regression).

## Risks & open questions

1. **`ul_run_step` commit-on-success behavior is opaque** (external nix-repo-base lib). The rollback-on-verify-fail strategy assumes the nvfetcher step commits and `git reset --hard HEAD~1` is sufficient. Plan must verify this empirically against the current `nix-repo-base` revision before relying on it.
2. **Upstream provenance gap.** If both beads-web and cmux publish no provenance, the hard-fail mode means the nightly bot can never update either binary. Decision deferred to plan/implementation phase: if the audit finds zero provenance on either upstream, the implementer pauses and asks for the gap-handling preference (pin-and-document, vs. ship the hard-fail and accept stuck binaries until upstream fixes it).
3. **Corrupt-`flake.lock` guard narrows the self-repair surface.** `update-locks.sh:32-39`'s self-repair fallback (empty `nix-repo-base` rev → unpinned HEAD) currently absorbs *any* failure to resolve the lock — including legitimate corruption. The tc-0ixb2 guard intentionally breaks that absorption for syntactic corruption (`jq -e '.' flake.lock` fails). **Trade-off:** in a hypothetical incident where the lock is corrupt *and* nix-repo-base is also unreachable, today's behavior would proceed via unpinned HEAD; the new behavior aborts and requires manual `git checkout HEAD -- flake.lock`. This is the desired semantics — corruption should not be silently routed around — but worth flagging because it does change the resilience design's failure-mode envelope. The nix-repo-base resilience doc (2026-05-29, lines 35, 262) covers the unpinned-HEAD fallback; this guard runs *before* that fallback and supersedes it for the corrupt case only. Missing-lock case is unchanged.
4. **Homelab consumer audit captured in spec.** Grep on `homelab/nix --include="*.nix"` for `pkgs.{beads-web,bat-gherkin-syntax,cmux}` and the named tmux plugin attrs returned no matches as of 2026-06-18. Spec's consumer impact table treats homelab as no-change. Implementer re-confirms with the same grep before the post-merge follow-up.
5. **`phillipgreenii.user.*` HM module attribute collision.** nix-personal exposes a `phillipgreenii` *module* path at `flake.nix:192,241` for the HM forwarder. The new `pkgs.phillipgreenii.*` attribute is in a different namespace (NixOS/HM modules vs. pkgs), so there's no direct conflict — but worth a spec comment so the implementer doesn't second-guess the name.
6. **flake-parts and A4** look attractive *after* this chunk because the namespace cleanup reduces the surface area for a flake-parts conversion. Not in scope; noted for the next planning conversation.

## Out of scope (carryover beads still open)

- tc-iv7vz — cmux APFS DMG unpacking (separate hotfix branch)
- tc-21ql1 — Allow auto-merge repo setting (one-click on github.com)
- tc-n22q9 — Observe first post-Chunk-5 nightly (gated on the above two)
- tc-w2pr4 — SHA-pin actions + Renovate decision (deferred from this chunk's brainstorm)

## Inputs / outputs summary

| | Consumes | Produces |
|---|---|---|
| A5 | post-Chunk-5 overlay shape | `phillipgreenii.{...}` namespaced overlay + matching `packages.${system}` output |
| A7 | post-A5 overlay shape | gascity-free `nvfetcher.toml`, regenerated `_sources/generated.nix`, no `packages/gascity/` |
| B8 | sources.bat-gherkin-syntax | proper `stdenvNoCC.mkDerivation` with `pname`/`version`/`meta` |
| B9 + S6 | post-A5 `flake.nix`; `treefmt.nix`; `packages/yaziPlugins/default.nix`; `ci.yml`; `update-flakes.yml` | trimmed nits, no `id-token: write`, no duplicate fmt step |
| tc-0ixb2 | `update-locks.sh` | early guard distinguishing missing vs corrupt `flake.lock` |
| tc-34rqk | `packages/cmux/default.nix`; `flake.nix` darwin gate | cmux outputs only on aarch64-darwin |
| S3/M6 | nvfetcher source delta on each run | `verify-provenance.sh` + new `ul_run_step` in `update-locks.sh` + README provenance state table |

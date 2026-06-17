# Chunk 2: Overlay Architecture — Design

**Date:** 2026-06-17
**Source review:** [`2026-06-12-nix-overlay-deepdive.md`](../../../2026-06-12-nix-overlay-deepdive.md)
**Findings addressed:** A1 (overlay inversion), A2 (granular dependency injection)
**Estimated effort:** ~75 min implementation + CI cycles

## Goal

Invert the overlay so that packages are built against the *consumer's* nixpkgs (via `final.callPackage`), not against *this flake's* locked nixpkgs through `self.packages`. Switch every package derivation from `{ lib, pkgs }` (whole-pkgs injection) to granular dependency arguments so `callPackage`'s `.override` mechanism actually works and consumers can swap individual inputs.

Two branches; A2 first because it's mechanical and harmless under the current overlay shape, then A1 which restructures how `packages.${system}` is derived. After both land, `pkgs.beads-web` (under the overlay) and `<flake>.packages.${system}.beads-web` evaluate the *same* derivation through the *same* callPackage path, with consumer nixpkgs as the source of truth.

## Non-Goals

- **B5/B6** (dishonest `meta.platforms`, `lib.fakeHash` placeholders) → Chunk 3
- **S4/B10** (`/usr/bin/hdiutil`, `/usr/bin/codesign`, firefox overlay assertion) → Chunk 3
- **B2** (`fix-lint` broken) → Chunk 3
- **B9 nits** (`stdenv.isDarwin` deprecation, `mkApp` rewrite) → Chunk 6 unless trivially adjacent
- **`nix/update-*.nix` apps** — internal-only, never overridden, not in A1/A2's deepdive scope → Chunk 6 if at all
- **Chunk 1 Task 3's linux-exclusion filter** for `beads-web`/`gascity` — works unchanged because `packages.${system}` still includes those attrs (just sourced through `extended`); remove only when Chunk 3 fixes B5/B6

## Workflow

Two local branches off `main`, each pushed to `origin` for human-merge. **No PRs opened.** CI workflow only triggers on push-to-main / PR-against-main (discovered during Chunk 1), so per-branch CI is not available — verification is local via `nix flake check` and per-package `nix build`. CI runs after the human merges to main.

All work in the worktree `/home/tcadmin/workspace/nix-overlay-chunk1` (shared `.git` with the main checkout at `/home/tcadmin/workspace/nix-overlay`; main is checked out there, so this worktree branches directly off `origin/main`).

## Branch Order

```
A2 ──► A1
9 file sig conversions   overlay invert + packages re-derive
```

A2 first because:
- It's mechanical; each file independent.
- A2 changes are **harmless under the current overlay shape** (`pkgs.callPackage` accepts either `{ lib, pkgs }` or granular signatures), so the branch is shippable on its own.
- A1 depends on A2 to realize the benefit (`.override { fetchurl = ...; }` is only meaningful with granular deps).

## Branch 1 — `refactor/granular-package-deps` (A2)

### Problem
Every package in `packages/*` (except `yaziPlugins`) takes `{ lib, pkgs }`. Taking `pkgs` wholesale means:
- `callPackage`'s dependency injection only works at the `pkgs`-level (consumers can't swap a single dep).
- `.override { fetchurl = ...; }` granularity is lost.
- The derivation files don't *document* their actual dependencies.

`yaziPlugins/default.nix` is already the model — `{ lib, stdenvNoCC, callPackage, fetchFromGitHub }`.

### Per-file changes

For each file, replace the function signature with the minimal real deps, then substitute `pkgs.X` → `X` in the body. The deps below were determined by reading each file.

| File | Current | After | Notes |
|---|---|---|---|
| `packages/bat-gherkin-syntax/default.nix` | `{ lib, pkgs }` | `{ lib, fetchFromGitHub }` | Uses `lib.platforms.unix` in meta. |
| `packages/beads-web/default.nix` | `{ lib, pkgs }` | `{ lib, stdenv, fetchurl }` | Needs `stdenv` for `hostPlatform.system` and `stdenv.mkDerivation`. Drop the `with pkgs.lib;` in meta → `with lib;` (incidental B9 hit). |
| `packages/cmux/default.nix` | `{ lib, pkgs }` | `{ lib, stdenvNoCC, fetchurl }` | The `/usr/bin/hdiutil` strings stay as string literals (S4 territory, Chunk 3). |
| `packages/gascity/default.nix` | `{ lib, pkgs }` | `{ lib, stdenv, stdenvNoCC, fetchurl }` | Both `stdenv` (for `hostPlatform.system`) and `stdenvNoCC` (for `mkDerivation`). |
| `packages/tmux-open-nvim/default.nix` | `{ lib, pkgs }` | `{ lib, tmuxPlugins, fetchFromGitHub }` | `lib` only for `lib.platforms.unix` in meta. |
| `packages/tmux-mouse-swipe/default.nix` | `{ lib, pkgs }` | `{ lib, tmuxPlugins, fetchFromGitHub }` | Same shape as above. |
| `packages/tmux-nerd-font-window-name/default.nix` | `{ lib, pkgs }` | `{ lib, tmuxPlugins, fetchFromGitHub }` | Same. |
| `packages/c9watch/cli.nix` | `{ lib, pkgs }` | `{ lib, stdenv, stdenvNoCC, fetchurl }` | Same shape as gascity. |
| `packages/c9watch/gui.nix` | `{ lib, pkgs }` | `{ lib, stdenv, stdenvNoCC, fetchurl }` | `/usr/bin/codesign` string stays as literal (S4 territory). |

### Verification
1. `nix flake check --no-build` exits 0.
2. `nix build .#tmux-open-nvim .#tmux-mouse-swipe .#tmux-nerd-font-window-name .#bat-gherkin-syntax .#beads-web --no-link` succeeds. (`gascity` only if hash is real for the current host; skip on hash-failure platforms — that's B5/B6 territory.)
3. Spot-check one `.override` call: `nix eval --raw '(import <nixpkgs> { overlays = [ (import ./. {}).overlays.default ]; }).tmux-open-nvim.override { fetchFromGitHub = throw "overridden"; }' 2>&1 | grep -q overridden` should show the throw (proves override works).

### Risk / Rollback
A2 in isolation is a no-op for store paths: `pkgs.callPackage` injects deps the same way regardless of signature. If a file misses a dep, eval fails immediately with "function called without required argument 'X'" — easy to add. Rollback: one revert.

---

## Branch 2 — `refactor/invert-overlay` (A1)

### Problem
`flake.nix:114-134` defines `overlays.default = _final: prev: { ... inherit (ownPackages) ...; ... }` where `ownPackages = self.packages.${prev.stdenv.hostPlatform.system}`. Consequences for consumers applying `overlays.default`:

- Packages are built against *this flake's* locked nixpkgs (`nixpkgs-26.05-darwin @ 2262dac`), not the consumer's.
- Two nixpkgs evaluations per consumer (theirs + ours), with store-path divergence.
- Consumer overrides via `.overrideAttrs`/`.override` don't reach into our derivations.
- The yaziPlugins clause already does it right (Chunk 1 Task 1 partial fix).

### Change

**Rewire `overlays.default` (`flake.nix:114-134`).** Replace the `_final: prev: ... inherit (ownPackages) ...` block with `final: prev: ... final.callPackage ./packages/X { } ...` for every package:

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
    yaziPlugins = prev.yaziPlugins // (
      let ours = final.callPackage ./packages/yaziPlugins { };
      in { inherit (ours) icons-brew bunny; }
    );
  }
  // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
    cmux = final.callPackage ./packages/cmux { };
    c9watch-gui = final.callPackage ./packages/c9watch/gui.nix { };
    c9watch-cli = final.callPackage ./packages/c9watch/cli.nix { };
  };
```

The `let ownPackages = self.packages.${...}; in` binding goes away entirely.

**Re-derive `packages.${system}` from `pkgs.extend self.overlays.default` (`flake.nix:63-89`).** Replace the current `packages = { beads-web = pkgs.callPackage ./packages/beads-web { }; ... };` block with:

```nix
packages = let
  extended = pkgs.extend self.overlays.default;
in
  {
    inherit (extended)
      beads-web
      bat-gherkin-syntax
      gascity
      ;
    inherit (extended.tmuxPlugins)
      tmux-open-nvim
      tmux-mouse-swipe
      tmux-nerd-font-window-name
      ;
    yaziPlugins-icons-brew = extended.yaziPlugins.icons-brew;
    yaziPlugins-bunny = extended.yaziPlugins.bunny;

    fix-lint = pkgs.writeShellScriptBin "fix-lint" ''
      ${lib.getExe pkgs.statix} fix ${./.}
    '';
    install-pre-commit-hooks = pkgs.writeShellScriptBin "install-pre-commit-hooks" ''
      ${pre-commit.shellHook}
      echo "Pre-commit hooks installed successfully!"
      echo "Run 'pre-commit run --all-files' to test them."
    '';
  }
  // lib.optionalAttrs pkgs.stdenv.isDarwin {
    inherit (extended) cmux c9watch-gui c9watch-cli;
  };
```

`fix-lint` and `install-pre-commit-hooks` are not packages of *this overlay* (they're dev tooling exposed for `nix run`); leave them sourced from `pkgs` directly, not `extended`.

**Decisions baked in:**

1. **Keep `yaziPlugins-icons-brew` / `yaziPlugins-bunny` flat names in `packages`.** Added in Chunk 1 Task 1; consumer-facing. Removing them would be an interface break in Chunk 2 for no benefit (consumers can still use `extended.yaziPlugins.icons-brew` via the overlay).
2. **Keep `legacyPackages.yaziPlugins`** block unchanged from Chunk 1. Small explicit attrset; zero cost.
3. **`packages.${system}.fix-lint` and `install-pre-commit-hooks` remain built from `pkgs` not `extended`.** They are dev-shell utilities, not consumer-facing overlay packages.
4. **`extended` is built per-system inside `eachDefaultSystem`** — the existing `pkgs` binding (line 34: `pkgs = nixpkgs.legacyPackages.${system}`) is what we extend. No new top-level work.
5. **Don't touch `apps`** — they use `pkgs.callPackage` against `./nix/update-*.nix`. Out of scope; orthogonal.

### Verification
1. `nix flake check --no-build` exits 0.
2. `nix build .#beads-web .#bat-gherkin-syntax .#tmux-open-nvim .#yaziPlugins-icons-brew --no-link` all succeed.
3. **Consumer-side overlay test** (proves A1 actually inverted):
   ```bash
   nix eval --raw --impure --expr '
     let
       flake = builtins.getFlake (toString ./.);
       nixpkgs = builtins.getFlake "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
       pkgs = import nixpkgs.outPath {
         system = builtins.currentSystem;
         overlays = [ flake.overlays.default ];
       };
     in pkgs.beads-web.outPath
   '
   ```
   Expected: a `/nix/store/...` path. The consumer's `pkgs` has our `beads-web`.
4. **Override-granularity check** (proves A2 + A1 work together):
   ```bash
   nix eval --raw --impure --expr '
     let
       flake = builtins.getFlake (toString ./.);
       nixpkgs = builtins.getFlake "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
       pkgs = import nixpkgs.outPath {
         system = builtins.currentSystem;
         overlays = [ flake.overlays.default ];
       };
       overridden = pkgs.tmux-open-nvim.override { fetchFromGitHub = throw "override-reached"; };
     in overridden.outPath
   ' 2>&1
   ```
   Expected: error contains `override-reached` (or "function called without required argument"; either proves the override is plumbed through).
5. The Chunk 1 Task 3 `removeAttrs` filter still works (linux CI still builds the same subset).

### Risk / Rollback
- `pkgs.extend self.overlays.default` calls `final.callPackage` for every package — a typo in a package path is caught at eval time.
- **Store-path change is expected.** Packages were previously built via `pkgs.callPackage` against `nixpkgs-26.05-darwin@2262dac` (our locked nixpkgs); after this branch they're built via `extended.callPackage` where `extended` is also our locked nixpkgs (since `pkgs.extend` operates on the same base). For *us*, store paths should be identical. For *consumers*, store paths will change because they now use *their* nixpkgs. That's the point.
- Rollback: `git revert`. Caveat: reverting forces consumers back to two-nixpkgs evaluation; coordinate.

---

## Cross-Cutting

### Beads tracking
None. Chunk 1 didn't have beads tracking either; per-branch progress is implicit in git log. The two-branch structure is self-evident.

### Implementer prompt hygiene (lessons from Chunk 1)
The Chunk 1 Task 1 implementer opened a PR despite explicit instructions, because the CI workflow only triggers on push-to-main / PR. Chunk 2's implementer prompts must:
- Reiterate "no PR" rule prominently.
- Tell the implementer **not to wait for branch CI** (`gh run watch` will hang forever).
- Verification is local (`nix flake check` + `nix build`).

### Out-of-scope adjacent items intentionally NOT touched
- **B5/B6, S4/B10, B2**: see Non-Goals.
- **Task 3 linux exclusion filter**: stays.
- **Top-level attribute squatting (A5)**: orthogonal; deferred to Chunk 6.
- **`nix/update-*.nix` apps**: dev tooling, out of A1/A2 scope.

## Success Criteria

After both branches are merged:
1. Every `packages/*` file (except `nix/update-*.nix`) takes granular dependency arguments — no `{ lib, pkgs }` signatures remain.
2. `overlays.default` defines every package via `final.callPackage`, with no references to `self.packages` or `ownPackages`.
3. `packages.${system}` is derived from `pkgs.extend self.overlays.default` — single source of truth.
4. The consumer-overlay test (Verification step 3 above) succeeds.
5. The override-granularity test (Verification step 4 above) shows the override is reachable.
6. CI on `main` is green after each merge.

## Open Questions

None pending. All decisions were resolved in dialogue (granularity, decisions 1–5 above).

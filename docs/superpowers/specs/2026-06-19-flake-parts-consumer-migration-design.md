# nix-overlay — flake-parts Consumer Migration Design

**Status:** Draft
**Date:** 2026-06-19
**Bead epic:** tc-jdt36 (absorbs tc-zt0hh + tc-rzgzq remainder — close both on merge)
**Worktrees (planned):**

- spec: `/home/tcadmin/workspace/nix-overlay-flake-parts-spec` on `docs/flake-parts-consumer-spec`
- impl: `/home/tcadmin/workspace/nix-overlay-impl` on `feat/flake-parts-consumer`
  **Base:** `nix-overlay/main` at HEAD `e177a27`
  **Producer pin (target):** `phillipgreenii/nix-repo-base` `main` post-`ce158d0`
  **Source handoff:** `nix-repo-base/docs/superpowers/handoff/2026-06-19-consumer-migrations-prompt.md`

## 1. Goal

Migrate `nix-overlay/flake.nix` from `flake-utils.lib.eachDefaultSystem` to `flake-parts.lib.mkFlake`; replace the four `phillipgreenii-nix-base.lib.{mkChecks, mkPreCommitHooks, mkDevShell, mkInstallMetadata}` call sites with producer flake-module imports + a Shape-B `homeModules.install-metadata` wrapper; let `nix flake update` shrink the lock from ~26 nodes toward the ~6-node target tc-rzgzq cited.

Result: `nix flake check` passes; every package in `self.packages.${system}` still builds; the overlay surface (`overlays.default`, the back-compat ADR-0047 aliases, the firefox-binary-wrapper overlay) is byte-identical from a consumer's view.

## 2. Background

The 2026-06-18 producer chunk on `nix-repo-base/main` deleted `mkChecks`, `mkPreCommitHooks`, `mkDevShell`, `mkInstallMetadata` from `phillipgreenii-nix-base.lib`. The replacement shape is module imports (3 universal + 1 install-metadata HM module). nix-overlay calls all four deleted factories, and additionally still uses `flake-utils.lib.eachDefaultSystem` which the producer chunk's spec §M3 named as the migration target.

Two pre-existing beads describe this work:

- **tc-zt0hh** (P3, OPEN) — "nix-overlay: consider flake-parts migration (M3)". Deferred 2026-06-18 from Chunk 6; depends on tc-henah which is closed (✓).
- **tc-rzgzq** (P3, OPEN) — "nix-overlay: prune nix-repo-base transitive inputs (A4)". Deferred 2026-06-18 from Chunk 6; depends on tc-8rzk6 which is closed (✓).

The producer chunk made these no longer optional — they're "migrate or stay pinned to a producer rev that's now stale". tc-jdt36 absorbs both; close them on merge with reason "absorbed by tc-jdt36".

## 3. Decisions

### 3.1 flake-utils → flake-parts

`nix-overlay/flake.nix` lines 22-160 currently:

```nix
outputs = { self, nixpkgs, flake-utils, treefmt-nix, phillipgreenii-nix-base, ... }:
  flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;
      treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
      checks-lib = phillipgreenii-nix-base.lib.mkChecks pkgs;
      pre-commit = phillipgreenii-nix-base.lib.mkPreCommitHooks { inherit system; src = ./.; treefmtWrapper = treefmtEval.config.build.wrapper; };
      yaziPluginSet = pkgs.callPackage ./packages/yaziPlugins { };
    in {
      formatter = treefmtEval.config.build.wrapper;
      checks = { formatting = ...; linting = ...; } // self.packages.${system};
      devShells.default = phillipgreenii-nix-base.lib.mkDevShell {...};
      packages = let extended = pkgs.extend self.overlays.default; in { ... };
      legacyPackages = { yaziPlugins = { inherit (yaziPluginSet) icons-brew bunny; }; };
    }
  ) // {
    homeModules.install-metadata = phillipgreenii-nix-base.lib.mkInstallMetadata { ... };
    overlays.firefox-binary-wrapper = ...;
    overlays.default = final: prev: ...;
  };
```

After migration:

```nix
outputs = inputs@{ self, nixpkgs, flake-parts, phillipgreenii-nix-base, ... }:
  flake-parts.lib.mkFlake { inherit inputs; } {
    # Mirror flake-utils.lib.defaultSystems verbatim — verified at spec time as
    # ["aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux"]. Do NOT
    # drop x86_64-darwin (was missing in spec v1 — fixed here).
    systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];

    imports = [
      inputs.phillipgreenii-nix-base.flakeModules.pre-commit  # transitively imports treefmt
      inputs.phillipgreenii-nix-base.flakeModules.devshell
      inputs.phillipgreenii-nix-base.flakeModules.checks
    ];

    # Top-level (sibling of imports/systems/perSystem/flake) per the producer
    # devshell module's option location (devshell.nix:7 declares the option at
    # the top level; perSystem reads it via topLevelCfg).
    phillipgreenii.devshell.extraInputs = with nixpkgs.legacyPackages.x86_64-linux; [
      jq curl gnused nvfetcher
    ];

    perSystem = { self', inputs', pkgs, system, config, ... }:
      let
        yaziPluginSet = pkgs.callPackage ./packages/yaziPlugins { };
      in
      {
        # formatter, checks.{formatting, linting, pre-commit, consumer-input-alignment},
        # devShells.default, packages.install-pre-commit-hooks — all auto-contributed.
        # phillipgreenii.src defaults to inputs.self (no need to set ./.).

        # Build every package as a check. Use `config.packages` (same-perSystem-scope,
        # no `self` reentrance, no cross-system thunking) rather than `self.packages.${system}`
        # which forces an eval cycle through flake-parts' mkPerSystemFile machinery.
        # Spec v1 used `self.packages.${system}` — fixed here.
        checks = config.packages;

        packages =
          let
            extended = pkgs.extend self.overlays.default;
          in
          {
            inherit (extended.phillipgreenii) beads-web bat-gherkin-syntax;
            inherit (extended.tmuxPlugins) tmux-open-nvim tmux-mouse-swipe tmux-nerd-font-window-name;
            yaziPlugins-icons-brew = extended.yaziPlugins.icons-brew;
            yaziPlugins-bunny = extended.yaziPlugins.bunny;

            fix-lint = pkgs.writeShellScriptBin "fix-lint" ''
              exec ${pkgs.lib.getExe pkgs.statix} fix "''${@:-.}"
            '';
            # install-pre-commit-hooks REMOVED — pre-commit module auto-contributes it.
          }
          // pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin") {
            inherit (extended.phillipgreenii) cmux;
          };

        legacyPackages = {
          yaziPlugins = { inherit (yaziPluginSet) icons-brew bunny; };
        };
      };

    flake = {
      homeModules.install-metadata = { ... }: {
        imports = [ inputs.phillipgreenii-nix-base.homeModules.install-metadata ];
        phillipgreenii.install-metadata = {
          flakeSelf = self;
          name = "phillipgreenii-nix-overlay";
        };
      };

      overlays.firefox-binary-wrapper = import ./overlays/firefox-binary-wrapper.nix;
      overlays.default = final: prev:
        let sources = final.callPackage ./_sources/generated.nix { }; in
        {
          phillipgreenii = { ... };  # unchanged
          tmuxPlugins = ...;          # unchanged
          yaziPlugins = ...;          # unchanged
          # ADR-0047 back-compat aliases — unchanged
          inherit (final.phillipgreenii) beads-web bat-gherkin-syntax;
        } // prev.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-darwin") {
          inherit (final.phillipgreenii) cmux;
        };
    };
  };
```

Notes:

- `inputs.treefmt-nix.lib.evalModule pkgs ./treefmt.nix` is gone. **`./treefmt.nix` will be DELETED** (decided post-review, not OPTIONAL). Producer's `flake-modules/treefmt.nix` defaults add `prettier` (over `*.md`/`*.yaml`/`*.yml`/`*.json`) + `shfmt indent_size=2` beyond what nix-overlay's local file sets today. Both are improvements consistent with the phillipgreenii fleet. The first `nix fmt` after adoption WILL reformat md/yaml/json files in the repo; the plan must commit that reformat as a SEPARATE prep commit before the migration diff lands, so the migration's `git diff main` stays scoped to `flake.nix` + `flake.lock`. See AC #7.
- `checks-lib.linting ./.` is gone — `checks.linting` is auto-contributed against `phillipgreenii.src` (which defaults to `inputs.self`). The current `checks-lib.linting ./.` was scoping to flake root, which is the new default.
- The explicit `install-pre-commit-hooks` package is removed because the pre-commit module auto-contributes one at `perSystem.packages.install-pre-commit-hooks`.
- `// self.packages.${system}` merge that exposed every package as a check stays (folded into `checks = config.packages;` — flake-parts module merge replaces the `//` semantics; if any future package name collides with the four auto-contributed checks `formatting`/`linting`/`pre-commit`/`consumer-input-alignment`, the merge will hard-fail at eval time, which is the safer behavior).
- The note in the original about "if a future package name collides with formatting/linting, it will silently shadow the check" is obsoleted — module-system merge rejects conflicts at eval time.
- Systems list mirrors `flake-utils.lib.defaultSystems` exactly: all four entries, x86_64-darwin INCLUDED.

### 3.2 Inputs change

Currently (lines 4-20):

```nix
inputs = {
  nixpkgs.url = "...";
  flake-utils.url = "github:numtide/flake-utils";
  treefmt-nix.url = "github:numtide/treefmt-nix";
  treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  git-hooks.url = "github:cachix/git-hooks.nix";
  git-hooks.inputs.nixpkgs.follows = "nixpkgs";
  phillipgreenii-nix-base = {
    url = "github:phillipgreenii/nix-repo-base";
    inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-utils.follows = "flake-utils";
      treefmt-nix.follows = "treefmt-nix";
      git-hooks.follows = "git-hooks";
    };
  };
};
```

After migration:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
  flake-parts.url = "github:hercules-ci/flake-parts";
  phillipgreenii-nix-base = {
    url = "github:phillipgreenii/nix-repo-base";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};
```

Drops:

- `flake-utils` — no longer needed; flake-parts replaces it
- `treefmt-nix` — producer owns treefmt-nix transitively (only when the treefmt module is in scope, which it is via pre-commit)
- `git-hooks` — producer owns git-hooks transitively

The follows-stripping is intentional. The producer's own follows wiring is now correctly minimized post-2026-06-18 chunk; consumers no longer need to follows-rewrite producer-internal inputs.

### 3.3 Shape-B install-metadata wrapper

Currently (line 109):

```nix
homeModules.install-metadata = phillipgreenii-nix-base.lib.mkInstallMetadata {
  flakeSelf = self;
  name = "phillipgreenii-nix-overlay";
};
```

After migration (in the top-level `flake = { ... }` block):

```nix
homeModules.install-metadata = { ... }: {
  imports = [ inputs.phillipgreenii-nix-base.homeModules.install-metadata ];
  phillipgreenii.install-metadata = {
    flakeSelf = self;
    name = "phillipgreenii-nix-overlay";
  };
};
```

Downstream consumers of nix-overlay's `homeModules.install-metadata` (e.g. any future repo that imports `nix-overlay.homeModules.install-metadata` into a HM config) see a module with the same name shape — they import it and get the configured behavior with no further options to set. The Shape-B wrapper is the producer-spec-documented migration target (producer spec §3.2).

### 3.4 What is NOT changing

- Overlay surface: `overlays.default`, `overlays.firefox-binary-wrapper` — identical
- ADR-0047 back-compat aliases (lines 147-158 today): preserved unchanged; deletion tracked separately
- Package list under `self.packages.${system}` (beads-web, bat-gherkin-syntax, tmux-_, yaziPlugins-_, fix-lint, cmux on darwin): identical (less `install-pre-commit-hooks` which moves to module-contributed)
- `_sources/generated.nix` (nvfetcher output) — unchanged

### 3.5 Lock update

After file changes land:

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
nix flake update
```

Expected lock delta:

- `phillipgreenii-nix-base` advances to post-2026-06-18 main
- `flake-utils`, `treefmt-nix`, `git-hooks` REMOVED as top-level nodes (no longer consumer inputs)
- Producer's heavy transitive inputs (flox, fenix, crane, bun2nix, blueprint, rust-analyzer-src, nixpkgs duplicates) REMOVED — producer no longer owns them
- New top-level: `flake-parts` (and its `nixpkgs-lib`)
- Total nodes: realistic floor ~11-13 (NOT ~6). The producer chunk now ships flake-parts modules, which means the producer's own lock retains 9 non-root nodes (flake-compat, flake-parts, flake-utils, git-hooks, gitignore, gomod2nix, nixpkgs, systems, treefmt-nix). The consumer follows only `nixpkgs`, so the consumer's lock = `root + nixpkgs + flake-parts (+ nixpkgs-lib) + phillipgreenii-nix-base + 8 producer transitives ≠ nixpkgs ≈ 12 nodes`. The original tc-rzgzq target of ~6 predates this modularization — revise downward expectations accordingly. Acceptance criterion #6 caps at ≤ 14 with margin.

## 4. Acceptance

A merge is acceptable when all of the following hold in the impl worktree at the head of `feat/flake-parts-consumer`:

1. `nix flake check` exits 0 — runs `consumer-input-alignment`, `formatting`, `linting`, `pre-commit`, plus the package-as-check slice. (No `--no-build`: `consumer-input-alignment` is a `runCommand` that must build to assert.)
2. `nix build .#packages.x86_64-linux.beads-web` succeeds.
3. `nix build .#packages.x86_64-linux.bat-gherkin-syntax` succeeds.
4. `nix build .#packages.x86_64-linux.tmux-open-nvim` succeeds (sample tmux plugin).
5. `nix build .#packages.aarch64-darwin.cmux` succeeds on a darwin host (deferred CI check if no darwin runner available).
6. **aarch64-linux eval coverage:** `nix flake check --system aarch64-linux` exits 0 — proves the systems list expansion holds for the second non-x86 system. (Eval-only; no remote build needed.)
7. `nix flake metadata --json | jq '.locks.nodes | length'` reports ≤ 14 nodes (realistic floor ~11-13; cap allows margin for one unexpected addition).
8. `git diff main -- flake.nix flake.lock` is the full migration diff; **`treefmt.nix` is DELETED** in a separate prep commit on the same branch (see §3.1 note); any md/yaml/json reformat is a SECOND prep commit. No other unrelated files change.
9. `pre-commit run --from-ref main --to-ref HEAD` (scoped to migration changes) passes.
10. The Shape-B wrapper for `homeModules.install-metadata` is correctly shaped: `nix eval --raw .#homeModules.install-metadata --apply 'm: if builtins.isFunction m then "function" else "non-function"'` returns `"function"`. (You cannot eval `.options` on a bare module — it must be evaluated inside a HM config context. A throwaway HM eval test fixture under `tests/` is optional but recommended; minimum bar is to confirm the export is a function-shaped HM module.)

## 5. Risks & mitigations

| Risk                                                                                                             | Mitigation                                                                                                                                                                                                                                                                                                                                                                                                     |
| ---------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `treefmt.nix` config differs from producer defaults and silently stops applying                                  | Implementer diffs `nix-overlay/treefmt.nix` against producer's `flake-modules/treefmt.nix`. If overrides exist, migrate to `perSystem.treefmt.*` options. If they match defaults, delete `treefmt.nix`.                                                                                                                                                                                                        |
| pre-commit module's auto-contributed `install-pre-commit-hooks` package name collides with existing exports      | Producer spec confirms the module exposes it at `perSystem.packages.install-pre-commit-hooks` — same path nix-overlay uses today. Removing our explicit definition resolves the collision.                                                                                                                                                                                                                     |
| Lock shrinks by more than expected, dropping a node a sibling package needs                                      | `nix flake check` builds every package as a check (§3.1 final clause). Failures surface immediately.                                                                                                                                                                                                                                                                                                           |
| ADR-0047 back-compat alias block fails to evaluate under flake-parts (less likely)                               | Block is plain Nix attrs inside `flake.overlays.default` — flake-parts doesn't touch overlay closures. Low risk; alignment check covers if any input is implicitly required.                                                                                                                                                                                                                                   |
| `phillipgreenii.devshell.extraInputs` option shape (list vs. function) differs from `mkDevShell extraInputs` arg | Implementer reads producer's `flake-modules/devshell.nix` to confirm. If incompatible, file separate producer-side bead (out of scope) and pin to last-good producer rev with the matching API.                                                                                                                                                                                                                |
| `consumer-input-alignment` flags a heavy input we didn't realize was needed                                      | Spec confirms: nix-overlay imports NO overlay flake modules (no unstable, no llm-agents, no vscode-extensions, no flox). Alignment check is effectively a no-op for this consumer. If it fires, the message names the missing input.                                                                                                                                                                           |
| Prettier-on-existing-files reformat balloons the migration diff                                                  | Adoption of producer's treefmt defaults will reformat `*.md`/`*.yaml`/`*.yml`/`*.json` files in the repo on first `nix fmt`. Plan must commit the reformat as a SEPARATE prep commit before the migration diff lands. Implementer runs `nix fmt` immediately after adopting the new treefmt module and inspects the diff for surprises (e.g., a YAML file where prettier's wrap differs sharply from current). |
| `checks = self.packages.${system}` evaluation cycle vs `config.packages`                                         | Spec v1 used `self.packages.${system}` which would force a cross-attr eval cycle through flake-parts' mkPerSystemFile. Fixed to `config.packages` (same-perSystem-scope). Plan-phase implementer should not "improve" this back.                                                                                                                                                                               |
| `x86_64-darwin` accidentally dropped from systems list                                                           | Spec v1 omitted `x86_64-darwin` from systems list (only listed 3 of 4 defaults). Fixed by mirroring `flake-utils.lib.defaultSystems` exactly. Plan-phase implementer should not "simplify" the list back to 3 entries.                                                                                                                                                                                         |

## 6. Out of scope

- Producer-side changes
- ADR-0047 alias deletion
- nvfetcher/source-package refactoring
- Adding new packages
- Changing the `_sources/generated.nix` workflow

## 7. References

- Handoff: `/home/tcadmin/workspace/nix-repo-base/docs/superpowers/handoff/2026-06-19-consumer-migrations-prompt.md`
- Producer README: `/home/tcadmin/workspace/nix-repo-base/README.md`
- Producer spec: `/home/tcadmin/workspace/nix-repo-base/docs/superpowers/specs/2026-06-18-flake-parts-modular-producer-design.md`
- Producer consumer-fixture: `/home/tcadmin/workspace/nix-repo-base/tests/consumer-fixture/flake.nix`
- Bead epic: tc-jdt36 (this epic)
- Absorbs: tc-zt0hh (flake-parts M3, OPEN), tc-rzgzq (A4 lock prune, OPEN) — close both on merge
- Sibling chunks: tc-0nze2 (homelab, independent), tc-r8brx (nix-personal, blocked by this epic)
- Memory: `[[feedback-use-worktrees]]`, `[[feedback-pin-is-the-version]]`, `[[feedback-grep-not-canonical-consumers]]`

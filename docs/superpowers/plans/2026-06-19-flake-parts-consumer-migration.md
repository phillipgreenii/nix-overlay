# nix-overlay flake-parts Consumer Migration Implementation Plan

**Goal:** Convert `nix-overlay/flake.nix` from `flake-utils.lib.eachDefaultSystem` to `flake-parts.lib.mkFlake`; swap four `phillipgreenii-nix-base.lib.{mkChecks,mkPreCommitHooks,mkDevShell,mkInstallMetadata}` call sites for flake-module imports + Shape-B install-metadata wrapper; shrink the lock from producer's transitive bloat.

**Architecture:** One large flake.nix rewrite, `treefmt.nix` deletion in its OWN prep commit, md/yaml/json reformat in a SECOND prep commit, then the migration commit, then the lock-update commit. The new perSystem uses `config.packages` (not `self.packages.${system}`) for the package-as-check pattern to avoid eval cycles. All four `flake-utils.lib.defaultSystems` entries (including `x86_64-darwin`) preserved.

**Tech Stack:** Nix flakes (Nix ≥ 2.18), flake-parts (new direct dep), `bd` for tracking.

## Global Constraints

- Producer pin advances to `phillipgreenii/nix-repo-base` `main` post-`ce158d0`
- Producer post-2026-06-18 inputs (verified at plan-write time): `{ nixpkgs, flake-parts, git-hooks, treefmt-nix, gomod2nix }`. Only `flake-utils` and the heavy inputs were dropped from the producer.
- No producer-side changes
- `phillipgreenii.src` defaults to `inputs.self`; do NOT explicitly set
- Worktree: `/home/tcadmin/workspace/nix-overlay-impl` on branch `feat/flake-parts-consumer`
- Every bash block starts with explicit `cd` — CWD resets between bash invocations
- Acceptance gates from `docs/superpowers/specs/2026-06-19-flake-parts-consumer-migration-design.md` §4 are authoritative; spec AC #8 requires TWO separate prep commits (treefmt.nix deletion + reformat scatter) BEFORE the migration commit
- This epic ABSORBS tc-zt0hh + tc-rzgzq — close all three on merge (multi-ID form supported: `bd close tc-jdt36 tc-zt0hh tc-rzgzq --reason="..."`)
- Lessons from tc-0nze2 (homelab) must already be applied to this plan before implementation starts — Task 7 of homelab's plan covers that handoff
- **Known producer-side limitation (devshell extras are system-agnostic by API):** the producer's `phillipgreenii.devshell.extraInputs` option is a flat `listOf package` evaluated once at top-level. Hardcoding `inputs.nixpkgs.legacyPackages.x86_64-linux.<pkg>` works for system-agnostic-named packages like `jq`/`curl`/`gnused`/`nvfetcher` (they exist on every system) but the resulting devshell only works correctly on x86_64-linux. nix-overlay's primary dev host is Linux; this is acceptable. Track a producer-side follow-up bead after this chunk closes.
- Final task (Task 8) runs `sp-bd-bridge:lessons-learned-extractor` and applies output to tc-r8brx's spec/plan

---

### Task 1: Create the impl worktree

**Files:**

- Create: branch `feat/flake-parts-consumer` from `main`
- Create: worktree at `/home/tcadmin/workspace/nix-overlay-impl`

**Interfaces:**

- Consumes: nothing (after tc-0nze2 close + lessons-learned application)
- Produces: a clean impl worktree

- [ ] **Step 1: Verify main is clean**

```bash
cd /home/tcadmin/workspace/nix-overlay
git status --porcelain && git fetch origin && git log --oneline main..origin/main | head -5
```

Expected: empty status; no commits behind.

- [ ] **Step 2: Create the worktree**

```bash
git worktree add -b feat/flake-parts-consumer /home/tcadmin/workspace/nix-overlay-impl main
```

Expected: `Preparing worktree (new branch 'feat/flake-parts-consumer')`.

- [ ] **Step 3: Update bead with worktree metadata**

```bash
bd update tc-jdt36 --notes="Impl worktree: /home/tcadmin/workspace/nix-overlay-impl on feat/flake-parts-consumer"
```

---

### Task 2: Prep — delete `treefmt.nix` (1st of two prep commits)

**Files:**

- Delete: `/home/tcadmin/workspace/nix-overlay-impl/treefmt.nix`

**Interfaces:**

- Consumes: spec AC #8 requires treefmt.nix deletion in its OWN commit, separate from the reformat scatter
- Produces: a single small prep commit that removes the file

- [ ] **Step 1: Delete `treefmt.nix`**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
git rm treefmt.nix
```

Expected: `rm 'treefmt.nix'`.

- [ ] **Step 2: Commit**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
git commit -m "treefmt: delete local treefmt.nix (superseded by producer module)

Producer's phillipgreenii-nix-base.flakeModules.treefmt (transitively
imported by flakeModules.pre-commit) replaces the local treefmt.nix.
Producer's defaults add prettier over *.md/*.yaml/*.yml/*.json and
shfmt indent_size=2 — the Task 3 reformat-scatter commit captures
the resulting file changes separately.

Refs: tc-jdt36"
```

---

### Task 3: Prep — reformat scatter against producer's treefmt defaults (2nd of two prep commits)

**Files:**

- Modify (auto): any `*.md` / `*.yaml` / `*.yml` / `*.json` / `*.sh` files that the producer's treefmt defaults reformat

**Interfaces:**

- Consumes: producer's treefmt defaults (prettier + shfmt indent 2)
- Produces: a single commit containing only the reformat, scoped via the pinned nixpkgs from the current flake.lock (NOT the global registry) so the result matches what `nix fmt` will produce post-migration

- [ ] **Step 1: Run the producer's exact prettier + shfmt against the repo (pinned via the consumer's nixpkgs lock entry)**

The flake.nix at this point still uses flake-utils (Task 4 will migrate). The producer's prettier+shfmt versions are determined by the producer's nixpkgs, which the consumer follows on `nixpkgs`. Use the CONSUMER's locked nixpkgs for invocation so the prettier rev matches what the post-migration treefmt module will use:

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
NIXPKGS_REV=$(jq -r '.nodes.nixpkgs.locked.rev' flake.lock)
echo "Reformatting via nixpkgs rev ${NIXPKGS_REV} (matches the consumer's pin)"
nix run "github:NixOS/nixpkgs/${NIXPKGS_REV}#nodePackages.prettier" -- --write '**/*.md' '**/*.yaml' '**/*.yml' '**/*.json' 2>&1 | tail -10
nix run "github:NixOS/nixpkgs/${NIXPKGS_REV}#shfmt" -- -w -i 2 $(find . -name '*.sh' -not -path './.git/*' -not -path './result/*') 2>&1 | tail -5
```

Expected: prettier prints file paths it reformatted; shfmt is silent.

- [ ] **Step 2: Inspect the diff**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
git diff --stat
git diff 2>&1 | head -50
```

Expected: a list of `*.md`/`*.yaml`/`*.yml`/`*.json`/`*.sh` modifications, NO `treefmt.nix` (already gone from Task 2), NO `flake.nix` change. Spot-check that no semantic content shifted (a YAML key rename, a markdown code-fence tag drop, a script logic change).

If anything semantic shifted, STOP and investigate — prettier-format quirk.

If nothing changed, skip Step 3 (no commit to make) and proceed to Task 4 — note in the merge commit that no reformat was needed.

- [ ] **Step 3: Commit the prep**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
git add -A
git commit -m "reformat: adopt phillipgreenii-nix-base treefmt defaults

Producer's flake-modules/treefmt.nix enables prettier over
*.md/*.yaml/*.yml/*.json and sets shfmt indent_size=2 — beyond
what the old local treefmt.nix configured. Reformatted via
prettier + shfmt pinned to the consumer's flake.lock nixpkgs
rev to match post-migration nix fmt output exactly.

Refs: tc-jdt36"
```

---

### Task 4: Rewrite `nix-overlay/flake.nix` — outputs scaffold + inputs trim

**Files:**

- Modify: `/home/tcadmin/workspace/nix-overlay-impl/flake.nix` (entire file, ~161 lines pre-migration)

**Interfaces:**

- Consumes: producer post-`ce158d0` exposes `flakeModules.{pre-commit, devshell, checks}`, `homeModules.install-metadata` (configurable Shape-B), `phillipgreenii.devshell.extraInputs` option at top-level, `_module.args.checksHelpers` (not needed here, no opt-in checks beyond auto-contributed)
- Produces: full flake-parts shape with the same overlay surface, same package list (minus `install-pre-commit-hooks` which is module-contributed), same `homeModules.install-metadata` export (Shape-B wrapper)

- [ ] **Step 1: Replace inputs**

REPLACE lines 1-20 (the entire `inputs = { ... }` block):

```nix
{
  description = "Third-party Nix packages absent from or outdated in nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    flake-parts.url = "github:hercules-ci/flake-parts";
    phillipgreenii-nix-base = {
      url = "github:phillipgreenii/nix-repo-base";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
```

(`flake-utils`, `treefmt-nix`, `git-hooks` removed — no longer consumer inputs; producer owns them transitively.)

- [ ] **Step 2: Replace outputs**

REPLACE lines 22-160 (the entire `outputs = ...` body):

```nix
  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      phillipgreenii-nix-base,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Mirror flake-utils.lib.defaultSystems verbatim — do NOT drop x86_64-darwin.
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      imports = [
        # pre-commit transitively imports treefmt
        inputs.phillipgreenii-nix-base.flakeModules.pre-commit
        inputs.phillipgreenii-nix-base.flakeModules.devshell
        inputs.phillipgreenii-nix-base.flakeModules.checks
      ];

      # Top-level option — see nix-repo-base/flake-modules/devshell.nix:7.
      # KNOWN LIMITATION: this option is a flat `listOf package` evaluated once;
      # hardcoding x86_64-linux means the devshell only works correctly on
      # x86_64-linux. nix-overlay's primary dev host is Linux. Track a
      # producer-side follow-up bead to make this option per-system-aware.
      phillipgreenii.devshell.extraInputs = with nixpkgs.legacyPackages.x86_64-linux; [
        jq
        curl
        gnused
        nvfetcher
      ];

      perSystem =
        {
          self',
          inputs',
          pkgs,
          system,
          config,
          ...
        }:
        let
          yaziPluginSet = pkgs.callPackage ./packages/yaziPlugins { };
        in
        {
          # formatter, devShells.default, packages.install-pre-commit-hooks,
          # checks.{formatting, linting, pre-commit, consumer-input-alignment}
          # — all auto-contributed.

          # Build every package as a check. Use config.packages (same-perSystem
          # scope) rather than self.packages.${system} which forces an eval
          # cycle through flake-parts' mkPerSystemFile.
          checks = config.packages;

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
        # Shape-B wrapper: imports the producer's HM module and sets options
        # with this flake's self + name. Downstream consumers see the configured
        # module shape (no further options to set).
        homeModules.install-metadata = { ... }: {
          imports = [ inputs.phillipgreenii-nix-base.homeModules.install-metadata ];
          phillipgreenii.install-metadata = {
            flakeSelf = self;
            name = "phillipgreenii-nix-overlay";
          };
        };

        overlays.firefox-binary-wrapper = import ./overlays/firefox-binary-wrapper.nix;

        overlays.default =
          final: prev:
          let
            sources = final.callPackage ./_sources/generated.nix { };
          in
          {
            phillipgreenii = {
              beads-web = final.callPackage ./packages/beads-web { inherit sources; };
              bat-gherkin-syntax = final.callPackage ./packages/bat-gherkin-syntax { inherit sources; };
            }
            // prev.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-darwin") {
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

            # TEMPORARY back-compat bridge for the A5 namespacing migration
            # (commit 1b17129 moved overlay packages under `phillipgreenii.*`).
            # Unmigrated consumers (nix-personal, agent-support) still reference
            # the old top-level names, so re-expose aliases to keep them building
            # until the consumer-side ADR-0047 migration lands. Remove then.
            # NOTE: c9watch was genuinely dropped (not just moved) and so cannot
            # be aliased here — it is disabled at the consumer instead.
            inherit (final.phillipgreenii) beads-web bat-gherkin-syntax;
          }
          // prev.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-darwin") {
            # cmux only exists under phillipgreenii.* on aarch64-darwin (see above).
            inherit (final.phillipgreenii) cmux;
          };
      };
    };
}
```

- [ ] **Step 3: Verify parse**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
nix-instantiate --parse flake.nix > /dev/null && echo "PARSE OK"
```

Expected: `PARSE OK`.

- [ ] **Step 4: Commit**

```bash
git add flake.nix
git commit -m "nix-overlay: migrate to flake-parts; swap lib factories for flake modules

- outputs: flake-utils.lib.eachDefaultSystem -> flake-parts.lib.mkFlake
- systems: explicit [aarch64-darwin aarch64-linux x86_64-darwin x86_64-linux]
- imports: phillipgreenii-nix-base.flakeModules.{pre-commit,devshell,checks}
- drop inline mkTreefmtConfig / mkChecks / mkPreCommitHooks / mkDevShell
- checks = config.packages (avoids self.packages.\${system} eval cycle)
- homeModules.install-metadata: Shape-B wrapper (imports + sets options)
- inputs: drop flake-utils/treefmt-nix/git-hooks (producer owns transitively);
  add flake-parts
- install-pre-commit-hooks removed (module-contributed)

Refs: tc-jdt36 (absorbs tc-zt0hh, tc-rzgzq)"
```

---

### Task 5: Update lock + acceptance gates

**Files:**

- Modify: `/home/tcadmin/workspace/nix-overlay-impl/flake.lock`

**Interfaces:**

- Consumes: rewritten flake.nix from Task 4
- Produces: trimmed lock; green acceptance

- [ ] **Step 1: Capture pre-bump lock state**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
jq '.nodes | length' flake.lock > /tmp/nix-overlay-prebump-nodes.txt
jq -r '.nodes."phillipgreenii-nix-base".locked.rev' flake.lock > /tmp/nix-overlay-prebump-producer-rev.txt
cat /tmp/nix-overlay-prebump-nodes.txt
cat /tmp/nix-overlay-prebump-producer-rev.txt
```

Expected: a number near 26 (matches tc-rzgzq's recorded baseline) and the pre-migration producer rev.

- [ ] **Step 2: Run `nix flake update` and commit with a Refs trailer**

`nix flake update --commit-lock-file` auto-commits with `flake.lock: Update` only — no `Refs: tc-jdt36` trailer. Do the update without auto-commit, then commit manually with the trailer for searchability:

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
nix flake update 2>&1 | tail -30
git add flake.lock
git commit -m "flake.lock: Update (post-migration trim)

phillipgreenii-nix-base advances past ce158d0; flake-utils, treefmt-nix,
git-hooks drop from top-level; flake-parts (+ nixpkgs-lib) added; producer's
heavy transitives (flox, fenix, crane, bun2nix, blueprint, rust-analyzer-src,
nixpkgs duplicates) drop.

Refs: tc-jdt36"
```

Expected: `nix flake update` output includes `• Updated input 'phillipgreenii-nix-base': ...`. The manual commit makes the lock change discoverable via `git log --grep tc-jdt36`.

- [ ] **Step 3: Capture post-bump state and verify ceiling**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
jq '.nodes | length' flake.lock > /tmp/nix-overlay-postbump-nodes.txt
jq -r '.nodes."phillipgreenii-nix-base".locked.rev' flake.lock > /tmp/nix-overlay-postbump-producer-rev.txt
PRE=$(cat /tmp/nix-overlay-prebump-nodes.txt)
POST=$(cat /tmp/nix-overlay-postbump-nodes.txt)
echo "Pre: $PRE  Post: $POST"
echo "Producer rev: $(cat /tmp/nix-overlay-prebump-producer-rev.txt) -> $(cat /tmp/nix-overlay-postbump-producer-rev.txt)"
[ "$POST" -le 14 ] && echo "AC #7 PASS: $POST ≤ 14" || echo "AC #7 FAIL: $POST > 14"
```

Expected: PASS line. If FAIL, inspect which nodes weren't dropped — most likely a follows missing on phillipgreenii-nix-base, OR a producer-transitive that the producer chunk didn't actually drop. Cross-check via `jq -r '.nodes | keys[] | sort' flake.lock`.

- [ ] **Step 4: Run `nix flake check`**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
nix flake check 2>&1 | tail -10
```

Expected: exit 0. No `--no-build` (alignment derivation must build).

- [ ] **Step 5: Build sample packages (x86_64-linux)**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
nix build .#packages.x86_64-linux.beads-web --no-link 2>&1 | tail -5
nix build .#packages.x86_64-linux.bat-gherkin-syntax --no-link 2>&1 | tail -5
nix build .#packages.x86_64-linux.tmux-open-nvim --no-link 2>&1 | tail -5
```

Expected: all exit 0.

- [ ] **Step 6: aarch64-linux eval-only coverage**

`nix flake check --system <other-system>` is NOT eval-only — it submits build derivations for all `checks.<system>` outputs (including our package-as-check slice), which requires either a registered aarch64-linux builder or binfmt_misc. For pure eval coverage of the alternate-system surface, use `nix eval`:

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
nix eval .#checks.aarch64-linux --apply 'builtins.attrNames' 2>&1 | tail -5
nix eval .#packages.aarch64-linux --apply 'builtins.attrNames' 2>&1 | tail -5
```

Expected: both return an attribute name list (proves the systems list correctly expands aarch64-linux and the perSystem evaluates there). If you DO have an aarch64-linux builder configured, you can additionally run `nix flake check --system aarch64-linux` for full build coverage.

- [ ] **Step 7: cmux build on darwin (deferred if no darwin runner)**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
nix build .#packages.aarch64-darwin.cmux --no-link 2>&1 | tail -5
```

If on a darwin host: expect exit 0. If not on darwin: skip and add a note to the impl bead `--notes` field that this gate is deferred to darwin CI.

- [ ] **Step 8: Verify install-metadata HM module export shape**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
nix eval --raw .#homeModules.install-metadata --apply 'm: if builtins.isFunction m then "function" else "non-function"'
```

Expected: `"function"`.

- [ ] **Step 9: Run pre-commit scoped to migration**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
pre-commit run --from-ref main --to-ref HEAD 2>&1 | tail -10
```

Expected: all hooks pass.

- [ ] **Step 10: Render lock-delta artifact for bd close --reason and lessons-learned**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
cat > /tmp/nix-overlay-impl-lock-delta.md <<EOF
# tc-jdt36 lock delta
Pre-bump nodes: $(cat /tmp/nix-overlay-prebump-nodes.txt)
Post-bump nodes: $(cat /tmp/nix-overlay-postbump-nodes.txt)
Producer rev: $(cat /tmp/nix-overlay-prebump-producer-rev.txt) -> $(cat /tmp/nix-overlay-postbump-producer-rev.txt)
Dropped top-level inputs: flake-utils, treefmt-nix, git-hooks
Added top-level inputs: flake-parts (+ nixpkgs-lib transitively)
EOF
cat /tmp/nix-overlay-impl-lock-delta.md
```

Consumed by Task 7 Step 4 (`bd close ... --reason`) and Task 8 Step 1 (lessons-learned-extractor prompt).

---

### Task 6: Verify no scope creep

**Files:**

- Read-only: `git diff main`

**Interfaces:**

- Consumes: completed migration
- Produces: confidence the diff is scoped exactly to the spec

- [ ] **Step 1: Inspect migration-scope diff**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
git diff main --stat
```

Expected files in the diff:

- `flake.nix` (rewritten)
- `flake.lock` (regenerated)
- `treefmt.nix` (deleted)
- A scatter of `*.md`/`*.yaml`/`*.yml`/`*.json`/`*.sh` reformats (from Task 3 prep commit — may be empty if no files needed reformatting)

NO Nix package files (`packages/**`), NO `_sources/generated.nix` modifications, NO overlay file (`overlays/firefox-binary-wrapper.nix`) changes. If any of those appear, STOP and investigate.

- [ ] **Step 2: Verify the per-commit scoping**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
git log --oneline main..HEAD
```

Expected: three to four commits in this order:

1. `treefmt: delete local treefmt.nix (superseded by producer module)` — from Task 2
2. (optional, only if reformat-scatter was non-empty) `reformat: adopt phillipgreenii-nix-base treefmt defaults` — from Task 3
3. `nix-overlay: migrate to flake-parts; ...` — from Task 4
4. `flake.lock: Update` — from Task 5

Each commit individually should make sense.

---

### Task 7: Merge to main + close epic + sibling beads

**Files:**

- Modify: `/home/tcadmin/workspace/nix-overlay/flake.nix`, `treefmt.nix` (delete), `flake.lock`, reformat scatter

**Interfaces:**

- Consumes: green acceptance from Task 5
- Produces: tc-jdt36 closed; tc-zt0hh + tc-rzgzq closed (absorbed)

- [ ] **Step 1: Rebase + re-validate**

```bash
cd /home/tcadmin/workspace/nix-overlay-impl
git fetch origin && git rebase origin/main
nix flake check 2>&1 | tail -10
nix build .#packages.x86_64-linux.beads-web --no-link 2>&1 | tail -5
```

Expected: clean rebase; `nix flake check` exit 0; package build succeeds. If conflicts during rebase, resolve (never destructive ops), then continue.

- [ ] **Step 2: FF-merge to main**

```bash
cd /home/tcadmin/workspace/nix-overlay
git fetch origin && git merge --ff-only feat/flake-parts-consumer
```

Expected: `Fast-forward`.

- [ ] **Step 3: Cleanup worktree + branch**

```bash
git worktree remove /home/tcadmin/workspace/nix-overlay-impl
git branch -d feat/flake-parts-consumer
```

- [ ] **Step 4: Close tc-jdt36 + absorbed beads**

```bash
cd /home/tcadmin/workspace/nix-overlay
# Guard: re-derive node counts from the merged flake.lock if /tmp files were cleared between sessions
PRE_NODES=$(test -s /tmp/nix-overlay-prebump-nodes.txt && cat /tmp/nix-overlay-prebump-nodes.txt || echo "<unknown>")
POST_NODES=$(jq '.nodes | length' nix-overlay/flake.lock 2>/dev/null || jq '.nodes | length' flake.lock)
bd close tc-jdt36 tc-zt0hh tc-rzgzq --reason="tc-jdt36 merged to nix-overlay/main; tc-zt0hh (flake-parts M3) and tc-rzgzq (A4 lock prune) absorbed. Lock dropped from ${PRE_NODES} -> ${POST_NODES} nodes."
```

(`bd close` accepts multiple IDs in one call per the bd CLI docs — verified at plan-write time.)

---

### Task 8: Lessons-learned loop — feed into tc-r8brx

**Files:**

- Modify: `/home/tcadmin/workspace/nix-personal/docs/superpowers/specs/2026-06-19-flake-parts-consumer-migration-design.md` (if lessons surface anything)
- Modify: `/home/tcadmin/workspace/nix-personal/docs/superpowers/plans/2026-06-19-flake-parts-consumer-migration.md` (if lessons surface anything)

**Interfaces:**

- Consumes: tc-jdt36 closure + git log on nix-overlay/main since pre-migration HEAD `e177a27`
- Produces: tc-r8brx unblocked + spec/plan refined

- [ ] **Step 1: Dispatch lessons-learned-extractor on tc-jdt36**

Use the Agent tool with `subagent_type: sp-bd-bridge:lessons-learned-extractor`. The prompt MUST name the context bead, give the base commit for git-log scoping, and list absolute artifact paths:

```
description: Extract lessons from tc-jdt36
prompt:
  Context bead: tc-jdt36 (nix-overlay consumer migration — CLOSED). Absorbs
  tc-zt0hh and tc-rzgzq (also CLOSED).
  Base commit (for git log scope): e177a27 (pre-migration HEAD recorded in the spec).
  Artifacts to read:
    /home/tcadmin/workspace/nix-overlay/docs/superpowers/specs/2026-06-19-flake-parts-consumer-migration-design.md
    /home/tcadmin/workspace/nix-overlay/docs/superpowers/plans/2026-06-19-flake-parts-consumer-migration.md
    /tmp/nix-overlay-impl-lock-delta.md
  Git log to scan:
    git -C /home/tcadmin/workspace/nix-overlay log e177a27..HEAD --oneline -- flake.nix flake.lock
  Cross-reference: `bd memories nix-overlay flake-parts; bd memories consumer-migration`
  to avoid redundant entries already recorded by tc-0nze2's lessons-extractor run.
  Record only NEW insights.
  Examples of high-value lessons to look for:
  - Producer treefmt-default reformat surprise (size of the reformat scatter)
  - Lock-node count reality vs the ≤14 ceiling
  - `checks = config.packages` evaluation behavior under flake-parts
  - Cross-flake follows alignment specifics (was `flake-parts.follows` actually needed?)
  - `nix flake check --system X` vs `nix eval` for alt-system coverage
  - Three-prep-commit-then-migration ordering — did it work cleanly?
  Record each via `bd remember "<insight with file path / command / error / fix>"`.
  At minimum, emit ONE `bd remember` call before returning.
```

- [ ] **Step 2: Read back lessons + apply to tc-r8brx spec/plan**

```bash
cd /home/tcadmin/workspace/nix-overlay
bd memories nix-personal flake-parts
bd memories consumer-migration
```

For each surfaced lesson that materially affects tc-r8brx, edit `/home/tcadmin/workspace/nix-personal/docs/superpowers/specs/2026-06-19-flake-parts-consumer-migration-design.md` and/or `/home/tcadmin/workspace/nix-personal/docs/superpowers/plans/2026-06-19-flake-parts-consumer-migration.md` (absolute paths — both files exist at plan-write time since all three plans were written together).

Where to put each lesson type:

- **Discovered risk** → new row in spec §5 (Risks & mitigations table)
- **Tightened acceptance gate** → modify the matching AC in spec §4
- **Improved tool invocation** → modify the matching plan task step's command
- **Process insight (cross-chunk)** → inline comment in plan's Global Constraints

After applying, update tc-r8brx's bead notes:

```bash
cd /home/tcadmin/workspace/nix-overlay
bd update tc-r8brx --notes="Post-tc-jdt36 lessons applied (in addition to post-tc-0nze2 set): <one-line per lesson>"
```

If zero applicable lessons surfaced, set `--notes="Post-tc-jdt36 lessons-extractor run; no spec/plan changes required."` to prove the gate ran.

- [ ] **Step 3: tc-r8brx unblocks**

Closing tc-jdt36 in Task 7 Step 4 satisfies the `blocks` dependency `tc-jdt36 -> tc-r8brx`. Verify:

```bash
cd /home/tcadmin/workspace/nix-overlay
bd ready 2>&1 | grep -E '^.\s+tc-r8brx'
```

Expected: a line containing `tc-r8brx`. If absent, run `bd show tc-r8brx` to inspect remaining blockers.

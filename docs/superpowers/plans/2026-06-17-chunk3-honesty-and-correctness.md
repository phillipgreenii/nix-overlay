# Chunk 3: Honesty & Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the lies in `meta.platforms`, drop `lib.fakeHash`, replace `/usr/bin/{hdiutil,codesign}` with proper Nix deps, fix `fix-lint`'s broken store-path interpolation, fail hard on hash-conversion errors, and delete unused c9watch.

**Architecture:** Three sequential branches off `main`. Branch 1 deletes c9watch entirely and restructures beads-web/gascity to use a single `supportedPlatforms` attrset that drives both `src` selection and `meta.platforms` (no drift possible). Branch 2 swaps `/usr/bin/hdiutil` for `undmg` in cmux and `/usr/bin/codesign` for `pkgs.darwin.sigtool` in the firefox overlay, plus adds the B10 assertion. Branch 3 rewrites `fix-lint` to operate on `$@` at runtime and removes the invalid-hash fallback from 3 updater scripts.

**Tech Stack:** Nix flakes (nixpkgs-26.05-darwin), `flake-utils.lib.eachDefaultSystem`, `pkgs.undmg`, `pkgs.darwin.sigtool`, bash for updater scripts.

**Source spec:** `docs/superpowers/specs/2026-06-17-chunk3-honesty-and-correctness-design.md`
**Source review:** `2026-06-12-nix-overlay-deepdive.md` (findings B5, B6, S4, B10, B2, S5)

## Global Constraints

These apply to every task; the implementer must internalize them before starting.

- **Work in the worktree at `/home/tcadmin/workspace/nix-overlay-chunk1`.** The sibling main checkout at `/home/tcadmin/workspace/nix-overlay` is separate (currently checked out to the spec branch). `main` is checked out in the sibling — you cannot `git checkout main` in this worktree. Branch directly off `origin/main` with `git checkout -b <branch> origin/main`.
- **No pull requests.** Never run `gh pr create` / `gh pr merge` / `gh pr` of any kind. Your job ends with `git push`; the human merges to `main` locally and pushes.
- **CI does not run on feature branches.** `.github/workflows/ci.yml` triggers only on push-to-main and PRs-against-main. Do NOT run `gh run watch` — it hangs forever. Verification is local: `nix flake check --no-build --show-trace` plus per-package `nix build`.
- **Vault key infra issue.** The remote builder `192.168.2.53` has been failing on derivations requiring `/run/vault-secrets/nix-signing-key.sec`. If `nix fmt` (or any other `nix` command) fails with "No such file or directory" for that path, retry with `--builders '' --max-jobs 4` to force local execution.
- **Platform support is match-current-usage-only:** aarch64-darwin + x86_64-linux for shared packages (beads-web, gascity). aarch64-darwin only for cmux. Any other system gets the throw.
- **Don't touch:** the `nix run nixpkgs#nix-prefetch-github` calls in `update-locks.sh` (Chunk 1 Task 4 disposition); Chunk 2's overlay or granular-deps wiring; the branch protection rule on `main`; `legacyPackages.yaziPlugins`.
- **Use the Edit tool for substitutions, not Write.** When the plan shows "Full post-edit content" as documentation, it's reference — apply each substitution as a targeted Edit. Hash values may drift from nightly bot runs between when this plan was written and when it executes; preserve current values if they conflict.

## Preconditions

1. The spec branch `docs/chunk3-honesty-correctness-spec` (which also contains this plan) has been merged into `main` and pushed. All implementation branches branch from the post-merge main so the docs travel with the code.
2. Worktree exists at `/home/tcadmin/workspace/nix-overlay-chunk1`. (Existed from Chunk 1/2; reused.)
3. Post-Chunk-2 `main` is at or after `74e77a6`.
4. `gh` CLI is authenticated as a user with write access to `phillipgreenii/nix-overlay`.

---

## Task 1: B1 — Drop c9watch, honest platforms, remove linux exclusion filter

**Why first:** Removes c9watch (cuts B2's `/usr/bin/codesign` users from two to one — only firefox left) and removes the Chunk-1-Task-3 linux-exclusion filter (which only existed because beads-web/gascity had `lib.fakeHash` for linux). Both ground-clearing.

**Files:**

- Delete: `packages/c9watch/cli.nix`
- Delete: `packages/c9watch/gui.nix`
- Delete (directory after files removed): `packages/c9watch/`
- Delete: `nix/update-c9watch.sh`
- Delete: `nix/update-c9watch.nix`
- Modify: `flake.nix` (`packages.${system}.darwin` darwin block; `overlays.default` darwin block; `apps.update-c9watch`; `checks` linux-exclusion filter)
- Modify: `update-locks.sh` (delete the `ul_run_step "update-c9watch" ...` block)
- Modify: `packages/beads-web/default.nix` (restructure to single `supportedPlatforms` attrset)
- Modify: `packages/gascity/default.nix` (same restructure)
- Modify: `nix/update-beads-web.sh` (drop darwin-x64; rewrite seds)
- Modify: `nix/update-gascity.sh` (drop darwin_amd64 + linux_arm64; rewrite seds)

**Interfaces:**

- Consumes: post-Chunk-2 state — packages take granular deps; overlay uses `final.callPackage`; `packages.${system}` derived from `pkgs.extend self.overlays.default`.
- Produces: beads-web and gascity each expose a `supportedPlatforms` attrset (single source of truth for both `src` and `meta.platforms`). Updater scripts target one-line attrset entries with anchored seds (no cross-platform contamination). c9watch is gone.

**Branch:** `fix/drop-c9watch-and-honest-platforms`

### Steps

- [ ] **Step 1.1: Create branch off updated origin/main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git fetch origin
git checkout -b fix/drop-c9watch-and-honest-platforms origin/main
git log --oneline origin/main -1
```

Expected: clean checkout, last commit on origin/main is at or after `74e77a6` (post-Chunk-2).

- [ ] **Step 1.2: Delete c9watch package files**

```bash
git rm packages/c9watch/cli.nix packages/c9watch/gui.nix
rmdir packages/c9watch
ls packages/ | grep c9watch && echo "STILL THERE — investigate" || echo "(c9watch dir gone — good)"
```

- [ ] **Step 1.3: Delete c9watch updater files**

```bash
git rm nix/update-c9watch.sh nix/update-c9watch.nix
```

- [ ] **Step 1.4: Remove c9watch from `flake.nix` (darwin packages block)**

Edit `flake.nix:106-108`. Replace:

```nix
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          inherit (extended) cmux c9watch-gui c9watch-cli;
        };
```

With:

```nix
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          inherit (extended) cmux;
        };
```

- [ ] **Step 1.5: Remove c9watch from `flake.nix` (overlay darwin block)**

Edit `flake.nix:161-165`. Replace:

```nix
        // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
          cmux = final.callPackage ./packages/cmux { };
          c9watch-gui = final.callPackage ./packages/c9watch/gui.nix { };
          c9watch-cli = final.callPackage ./packages/c9watch/cli.nix { };
        };
```

With:

```nix
        // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
          cmux = final.callPackage ./packages/cmux { };
        };
```

- [ ] **Step 1.6: Remove the `update-c9watch` app from `flake.nix`**

Edit `flake.nix` around line 125. Delete the line:

```nix
            update-c9watch = mkApp (pkgs.callPackage ./nix/update-c9watch.nix { });
```

The surrounding `apps` block stays.

- [ ] **Step 1.7: Remove the c9watch step from `update-locks.sh`**

Edit `update-locks.sh:112-114`. Delete the block:

```bash
ul_run_step "update-c9watch" \
  "update-locks: update c9watch" \
  nix run .#update-c9watch -- "${SCRIPT_DIR}"
```

- [ ] **Step 1.8: Sanity-check that no c9watch references remain**

```bash
grep -RIn c9watch . --exclude-dir=.git --exclude-dir=docs --exclude-dir=.update-locks --exclude=2026-06-12-nix-overlay-deepdive.md
```

Expected: no output. If any reference appears outside docs/historical files, investigate and remove. (The deepdive review doc and Chunk 1/2 specs/plans naturally still mention c9watch as historical context — those are out of scope.)

- [ ] **Step 1.9: Restructure `packages/beads-web/default.nix` to use `supportedPlatforms`**

Replace the entire file with:

```nix
{ lib, stdenv, fetchurl }:

let
  version = "0.11.2";

  supportedPlatforms = {
    aarch64-darwin = { artifact = "darwin-arm64"; hash = "sha256-6+4ddKilgMHFfSBSNCQNPl2jZDmNtWpQ99zKn2bWnkc="; };
    x86_64-linux = { artifact = "linux-x64"; hash = "sha256-eDL5aAwQ41XK58YFirf7HLvImxR5PJeFr6WIzmS5IRE="; };
  };

  current =
    supportedPlatforms.${stdenv.hostPlatform.system}
      or (throw "beads-web: ${stdenv.hostPlatform.system} not supported; build platforms: ${toString (builtins.attrNames supportedPlatforms)}");
in
stdenv.mkDerivation {
  pname = "beads-web";
  inherit version;

  src = fetchurl {
    url = "https://github.com/weselow/beads-web/releases/download/v${version}/beads-web-${current.artifact}";
    hash = current.hash;
  };

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    install -m755 $src $out/bin/beads-web
  '';

  meta = with lib; {
    description = "Visual Kanban UI for Beads CLI — real-time sync, epic tracking, GitOps";
    homepage = "https://github.com/weselow/beads-web";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "beads-web";
    platforms = builtins.attrNames supportedPlatforms;
  };
}
```

**Critical:** the `supportedPlatforms` entries must remain on ONE LINE each — `aarch64-darwin = { artifact = ...; hash = ...; };` all on one line. This format is what makes the updater's per-platform anchored sed unambiguous. Don't let nixfmt reflow this — the format should be acceptable to nixfmt as-is. If `nix fmt` does reflow them after Step 1.14, manually re-collapse and add `# nixfmt-disable` if needed (verify nixfmt doesn't try to split the line first; it likely won't if the line is under nixfmt's default width).

If the version `0.11.2` is no longer current at execution time (the nightly bot may have bumped it), the `darwin-arm64` hash also changes. Run:

```bash
nix store prefetch-file --json --hash-type sha256 \
  "https://github.com/weselow/beads-web/releases/download/v$(grep 'version = ' packages/beads-web/default.nix | head -1 | sed 's/.*"\(.*\)".*/\1/')/beads-web-darwin-arm64" \
  | jq -r .hash
```

Use the current version + computed hash in the new file. Same for the linux-x64 hash if it differs from the value shown above.

- [ ] **Step 1.10: Restructure `packages/gascity/default.nix` to use `supportedPlatforms`**

Replace the entire file with:

```nix
{ lib, stdenv, stdenvNoCC, fetchurl }:

let
  version = "1.2.1";

  supportedPlatforms = {
    aarch64-darwin = { artifact = "darwin_arm64"; hash = "sha256-xJ82ow1PdV0VSRI/ufx5NNwApf7BeffUBI0UF2pfD6s="; };
    x86_64-linux = { artifact = "linux_amd64"; hash = "sha256-erwm2CaIHTghlgDiXnigo2gC7d+ebtdwRidfXsnnIXI="; };
  };

  current =
    supportedPlatforms.${stdenv.hostPlatform.system}
      or (throw "gascity: ${stdenv.hostPlatform.system} not supported; build platforms: ${toString (builtins.attrNames supportedPlatforms)}");
in
stdenvNoCC.mkDerivation {
  pname = "gascity";
  inherit version;

  src = fetchurl {
    url = "https://github.com/gastownhall/gascity/releases/download/v${version}/gascity_${version}_${current.artifact}.tar.gz";
    hash = current.hash;
  };

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/bin
    install -m755 gc $out/bin/gc
  '';

  meta = with lib; {
    description = "Orchestration-builder SDK for multi-agent systems";
    homepage = "https://github.com/gastownhall/gascity";
    license = licenses.mit;
    mainProgram = "gc";
    platforms = builtins.attrNames supportedPlatforms;
  };
}
```

Note `stdenv` is still in the function signature even though we only use `stdenvNoCC.mkDerivation` for the build — `stdenv.hostPlatform.system` is the conventional source for the system string and `stdenv` is the same instance regardless. Could be `stdenvNoCC.hostPlatform.system` for symmetry; either works. The plan uses `stdenv` for consistency with beads-web.

If the version or hashes have drifted, recompute via the same `nix store prefetch-file` command shown in Step 1.9.

- [ ] **Step 1.11: Rewrite `nix/update-beads-web.sh` (drop darwin-x64; switch seds to anchored attrset form)**

Replace the entire file with:

```bash
#!/usr/bin/env bash
# Update beads-web package to latest GitHub release.
# Called from update-locks.sh before nix flake update.
#
# Downloads both supported-platform artifacts to get hashes, and updates
# version and hashes in packages/beads-web/default.nix if a newer release
# is available. Supported platforms: aarch64-darwin, x86_64-linux.

set -euo pipefail

REPO_ROOT="${1:-.}"
TARGET="${REPO_ROOT}/packages/beads-web/default.nix"

if [[ ! -f $TARGET ]]; then
  echo "Error: packages/beads-web/default.nix not found at $TARGET" >&2
  exit 1
fi

echo "Checking for beads-web updates..."

CURRENT_VERSION=$(grep 'version = ' "$TARGET" | head -1 | sed 's/.*version = "\([^"]*\)".*/\1/')

if [[ -z $CURRENT_VERSION ]]; then
  echo "  Error: Could not find current beads-web version in $TARGET" >&2
  exit 1
fi

echo "  Fetching latest release info..."
GH_HEADERS=()
if [[ -n ${GH_TOKEN:-} ]]; then
  GH_HEADERS+=(-H "Authorization: Bearer $GH_TOKEN")
fi
LATEST_TAG=$(curl -s "${GH_HEADERS[@]}" https://api.github.com/repos/weselow/beads-web/releases/latest | jq -r '.tag_name')
LATEST_VERSION="${LATEST_TAG#v}"

if [[ -z $LATEST_VERSION || $LATEST_VERSION == "null" ]]; then
  echo "  Error: Could not fetch latest release from GitHub" >&2
  exit 1
fi

if [[ $CURRENT_VERSION == "$LATEST_VERSION" ]]; then
  echo "  beads-web is up to date ($CURRENT_VERSION)"
  exit 0
fi

echo "  New beads-web release detected: $CURRENT_VERSION -> $LATEST_VERSION"
echo "  Fetching artifact hashes..."

DARWIN_ARM64_URL="https://github.com/weselow/beads-web/releases/download/v${LATEST_VERSION}/beads-web-darwin-arm64"
LINUX_X64_URL="https://github.com/weselow/beads-web/releases/download/v${LATEST_VERSION}/beads-web-linux-x64"

RAW_DARWIN_ARM64=$(nix-prefetch-url "$DARWIN_ARM64_URL" 2>/dev/null)
if [[ -z $RAW_DARWIN_ARM64 ]]; then
  echo "  Error: Could not prefetch $DARWIN_ARM64_URL" >&2
  exit 1
fi
RAW_LINUX_X64=$(nix-prefetch-url "$LINUX_X64_URL" 2>/dev/null)
if [[ -z $RAW_LINUX_X64 ]]; then
  echo "  Error: Could not prefetch $LINUX_X64_URL" >&2
  exit 1
fi

HASH_DARWIN_ARM64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_DARWIN_ARM64")
if [[ -z $HASH_DARWIN_ARM64 ]]; then
  echo "  Error: nix hash convert failed for $RAW_DARWIN_ARM64" >&2
  exit 1
fi
HASH_LINUX_X64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_LINUX_X64")
if [[ -z $HASH_LINUX_X64 ]]; then
  echo "  Error: nix hash convert failed for $RAW_LINUX_X64" >&2
  exit 1
fi

echo "  Updating packages/beads-web/default.nix..."
sed -i "s/version = \"$CURRENT_VERSION\";/version = \"$LATEST_VERSION\";/" "$TARGET"
sed -i "s|aarch64-darwin = { artifact = \"darwin-arm64\"; hash = \"[^\"]*\"; };|aarch64-darwin = { artifact = \"darwin-arm64\"; hash = \"$HASH_DARWIN_ARM64\"; };|" "$TARGET"
sed -i "s|x86_64-linux = { artifact = \"linux-x64\"; hash = \"[^\"]*\"; };|x86_64-linux = { artifact = \"linux-x64\"; hash = \"$HASH_LINUX_X64\"; };|" "$TARGET"

echo "  ✓ beads-web updated to $LATEST_VERSION"
```

The seds use single-space attrset formatting to match what nixfmt produces (nixfmt collapses multi-space alignment to single spaces). After `nix fmt` in Step 1.18, verify the format matches.

Two changes vs. the original script:

1. `darwin-x64` prefetch + hash computation + sed gone (platform dropped).
2. Hash-conversion fallback (`|| echo "sha256-$RAW"`) replaced with hard-fail (S5).
3. Seds now target the new one-line attrset shape (anchored on the platform key).
4. `set -euo pipefail` added at the top so any unguarded failure exits the script.

- [ ] **Step 1.12: Rewrite `nix/update-gascity.sh` (drop darwin_amd64 + linux_arm64; same shape as beads-web)**

Replace the entire file with:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Update gascity package to latest GitHub release.
# Called from update-locks.sh before nix flake update.
#
# Downloads both supported-platform artifacts to get hashes, and updates
# version and hashes in packages/gascity/default.nix if a newer release
# is available. Supported platforms: aarch64-darwin, x86_64-linux.

set -euo pipefail

REPO_ROOT="${1:-.}"
TARGET="${REPO_ROOT}/packages/gascity/default.nix"

if [[ ! -f $TARGET ]]; then
  echo "Error: packages/gascity/default.nix not found at $TARGET" >&2
  exit 1
fi

echo "Checking for gascity updates..."

CURRENT_VERSION=$(grep 'version = ' "$TARGET" | head -1 | sed 's/.*version = "\([^"]*\)".*/\1/')

if [[ -z $CURRENT_VERSION ]]; then
  echo "  Error: Could not find current gascity version in $TARGET" >&2
  exit 1
fi

echo "  Fetching latest release info..."
GH_HEADERS=()
if [[ -n ${GH_TOKEN:-} ]]; then
  GH_HEADERS+=(-H "Authorization: Bearer $GH_TOKEN")
fi
LATEST_TAG=$(curl -s "${GH_HEADERS[@]}" https://api.github.com/repos/gastownhall/gascity/releases/latest | jq -r '.tag_name')
LATEST_VERSION="${LATEST_TAG#v}"

if [[ -z $LATEST_VERSION || $LATEST_VERSION == "null" ]]; then
  echo "  Error: Could not fetch latest release from GitHub" >&2
  exit 1
fi

if [[ $CURRENT_VERSION == "$LATEST_VERSION" ]]; then
  echo "  gascity is up to date ($CURRENT_VERSION)"
  exit 0
fi

echo "  New gascity release detected: $CURRENT_VERSION -> $LATEST_VERSION"
echo "  Fetching artifact hashes..."

DARWIN_ARM64_URL="https://github.com/gastownhall/gascity/releases/download/v${LATEST_VERSION}/gascity_${LATEST_VERSION}_darwin_arm64.tar.gz"
LINUX_AMD64_URL="https://github.com/gastownhall/gascity/releases/download/v${LATEST_VERSION}/gascity_${LATEST_VERSION}_linux_amd64.tar.gz"

RAW_DARWIN_ARM64=$(nix-prefetch-url "$DARWIN_ARM64_URL" 2>/dev/null)
if [[ -z $RAW_DARWIN_ARM64 ]]; then
  echo "  Error: Could not prefetch $DARWIN_ARM64_URL" >&2
  exit 1
fi
RAW_LINUX_AMD64=$(nix-prefetch-url "$LINUX_AMD64_URL" 2>/dev/null)
if [[ -z $RAW_LINUX_AMD64 ]]; then
  echo "  Error: Could not prefetch $LINUX_AMD64_URL" >&2
  exit 1
fi

HASH_DARWIN_ARM64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_DARWIN_ARM64")
if [[ -z $HASH_DARWIN_ARM64 ]]; then
  echo "  Error: nix hash convert failed for $RAW_DARWIN_ARM64" >&2
  exit 1
fi
HASH_LINUX_AMD64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_LINUX_AMD64")
if [[ -z $HASH_LINUX_AMD64 ]]; then
  echo "  Error: nix hash convert failed for $RAW_LINUX_AMD64" >&2
  exit 1
fi

echo "  Updating packages/gascity/default.nix..."
sed -i "s/version = \"$CURRENT_VERSION\";/version = \"$LATEST_VERSION\";/" "$TARGET"
sed -i "s|aarch64-darwin = { artifact = \"darwin_arm64\"; hash = \"[^\"]*\"; };|aarch64-darwin = { artifact = \"darwin_arm64\"; hash = \"$HASH_DARWIN_ARM64\"; };|" "$TARGET"
sed -i "s|x86_64-linux = { artifact = \"linux_amd64\"; hash = \"[^\"]*\"; };|x86_64-linux = { artifact = \"linux_amd64\"; hash = \"$HASH_LINUX_AMD64\"; };|" "$TARGET"

echo "  ✓ gascity updated to $LATEST_VERSION"
```

Single-space attrset format (matches nixfmt output).

- [ ] **Step 1.13: Remove the linux-exclusion filter from `flake.nix` checks block**

Edit `flake.nix:48-66`. Replace:

```nix
        checks = {
          formatting = treefmtEval.config.build.check self;
          linting = checks-lib.linting ./.;
        }
        # Build every package in self.packages.${system} so CI exercises the
        # derivations, not just lint/format. On linux, exclude beads-web and
        # gascity until deepdive B5/B6 land (Chunk 3) — those packages ship
        # lib.fakeHash for linux and would always fail.
        # NOTE: if a future package name collides with "formatting" or
        # "linting", it will silently shadow the check.
        // (
          if pkgs.stdenv.hostPlatform.isLinux then
            removeAttrs self.packages.${system} [
              "beads-web"
              "gascity"
            ]
          else
            self.packages.${system}
        );
```

With:

```nix
        checks = {
          formatting = treefmtEval.config.build.check self;
          linting = checks-lib.linting ./.;
        }
        # Build every package in self.packages.${system} so CI exercises the
        # derivations, not just lint/format.
        # NOTE: if a future package name collides with "formatting" or
        # "linting", it will silently shadow the check.
        // self.packages.${system};
```

- [ ] **Step 1.14: Run `nix flake check --no-build` to verify eval succeeds**

```bash
nix flake check --no-build --show-trace
```

Expected: exits 0 with `all checks passed!`. If "function called without required argument" appears, the granular signature in beads-web or gascity is missing a dep — re-check Steps 1.9 / 1.10.

- [ ] **Step 1.15: Build beads-web and gascity locally to verify real hashes**

```bash
nix build .#beads-web --no-link
nix build .#gascity --no-link
```

Both must succeed (no `hash mismatch`). If hash mismatch: the inlined hash in Step 1.9 or 1.10 is stale — recompute via the `nix store prefetch-file --json` command in those steps.

- [ ] **Step 1.16: Verify the meta.platforms restriction is in place**

```bash
nix eval --json .#beads-web.meta.platforms
nix eval --json .#gascity.meta.platforms
```

Each should print `["aarch64-darwin","x86_64-linux"]` exactly. No overclaim.

- [ ] **Step 1.17: Smoke-test the updater seds (synthetic version stale)**

For beads-web only (gascity follows the same shape):

```bash
cp packages/beads-web/default.nix /tmp/beads-web-saved.nix

# Stale the version + hashes to force the updater to write
sed -i 's|version = "[0-9.]*"|version = "0.0.0"|' packages/beads-web/default.nix
sed -i 's|hash = "sha256-[^"]*"|hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA0="|g' packages/beads-web/default.nix

./nix/update-beads-web.sh "$(pwd)"

# Verify the diff shows BOTH hashes restored (or set to current upstream)
git diff packages/beads-web/default.nix | head -40

cp /tmp/beads-web-saved.nix packages/beads-web/default.nix
rm /tmp/beads-web-saved.nix
```

Expected diff: version flips back to upstream, both `aarch64-darwin` and `x86_64-linux` hash entries get rewritten with valid SRI hashes (sha256-... base64 form, NOT `sha256-AAAAAAAA...` placeholders or `sha256-<base32>` invalid form).

- [ ] **Step 1.18: Format and commit**

```bash
nix fmt  # if vault key error, use: nix fmt --builders '' --max-jobs 4
git status   # confirm: c9watch files deleted, flake.nix modified, beads-web/gascity modified, updaters modified, update-locks.sh modified
git diff --stat
git add -A   # captures both modifications and the rm's
git commit -m "$(cat <<'EOF'
fix: drop c9watch, honest meta.platforms, real linux hashes

c9watch removed entirely (user no longer uses it). Deletes packages/c9watch/,
nix/update-c9watch.{sh,nix}, the apps.update-c9watch entry, the
overlay/packages darwin entries, and the update-locks.sh step.

beads-web and gascity restructured to a single supportedPlatforms attrset
that drives both src selection and meta.platforms (no drift). meta.platforms
now equals exactly the platforms with real hashes:
- aarch64-darwin, x86_64-linux (both packages)
- darwin_amd64, linux_arm64, darwin-x64 dropped

Real linux-x64 hash computed for beads-web (was lib.fakeHash). Real
linux_amd64 hash for gascity was already present.

Updater scripts rewritten:
- Drop dropped-platform prefetches.
- Anchored seds target one-line attrset entries (aarch64-darwin = { ...; })
  so per-platform hash rewrites can't cross-contaminate.
- Fail hard on `nix hash convert` errors (drops the "sha256-$RAW"
  invalid-SRI fallback — deepdive S5).
- set -euo pipefail throughout.

flake.nix linux-exclusion filter (Chunk 1 Task 3 leftover) deleted: now
that beads-web and gascity build cleanly on linux, the filter is dead code.

Fixes deepdive findings B5, B6, and S5 (partial — invalid-hash fallback
also removed from update-cmux.sh in Chunk 3 Branch 3).
EOF
)"
```

- [ ] **Step 1.19: Push the branch**

```bash
git push -u origin fix/drop-c9watch-and-honest-platforms
```

Do NOT run `gh run watch`. Do NOT open a PR.

- [ ] **Step 1.20: Report and stop — wait for human merge**

Report status DONE. The human will fast-forward `main` to this branch and push, triggering CI on the merge.

---

## Task 2: B2 — Replace `/usr/bin/{hdiutil,codesign}` + B10 assertion

**Why second:** B1 just dropped c9watch (one of the two original `/usr/bin/codesign` users), so B2's surface shrinks. The remaining work is cmux (hdiutil → undmg) and firefox-binary-wrapper (codesign → darwin.sigtool, plus B10's assertion).

**Files:**

- Modify: `packages/cmux/default.nix` (signature + nativeBuildInputs + unpackPhase)
- Modify: `overlays/firefox-binary-wrapper.nix` (assertion + darwin.sigtool dep + PATH-resolved codesign)

**Interfaces:**

- Consumes: Task 1's c9watch removal; no shared state with Task 3.
- Produces: cmux now declares `undmg` as a granular dep; firefox overlay declares `prev.darwin.sigtool`. No `/usr/bin/` references remain in `packages/` or `overlays/`.

**Branch:** `fix/host-tool-replacements`

### Steps

- [ ] **Step 2.1: Create branch off updated origin/main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git fetch origin
git checkout -b fix/host-tool-replacements origin/main
git log --oneline origin/main -1
```

The current `origin/main` HEAD must include Task 1's commit (the c9watch removal). Confirm with `ls packages/c9watch 2>&1` returning "No such file or directory".

- [ ] **Step 2.2: Replace cmux's hdiutil dance with undmg**

Edit `packages/cmux/default.nix`. Replace the entire file with:

```nix
{ lib, stdenvNoCC, fetchurl, undmg }:
stdenvNoCC.mkDerivation rec {
  pname = "cmux";
  version = "0.64.16";

  src = fetchurl {
    url = "https://github.com/manaflow-ai/cmux/releases/download/v${version}/cmux-macos.dmg";
    hash = "sha256-QB/2emBrAzqkcKaLrVUZanK4qXHSma4CeJM2PwGhmXI=";
  };

  nativeBuildInputs = [ undmg ];

  unpackPhase = ''
    runHook preUnpack
    undmg "$src"
    runHook postUnpack
  '';

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/Applications $out/bin
    cp -r *.app $out/Applications/
    ln -s $out/Applications/cmux.app/Contents/Resources/bin/cmux $out/bin/cmux
    ln -s $out/Applications/cmux.app/Contents/Resources/bin/claude $out/bin/cmux-claude
  '';

  meta = with lib; {
    description = "Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents";
    homepage = "https://github.com/manaflow-ai/cmux";
    license = licenses.agpl3Plus;
    platforms = platforms.darwin;
  };
}
```

Three changes vs. current state:

1. Signature: `{ lib, stdenvNoCC, fetchurl, undmg }` (added `undmg`).
2. `nativeBuildInputs = [ ]` → `nativeBuildInputs = [ undmg ]`.
3. `unpackPhase` body: `mnt=$(mktemp -d)` + `hdiutil attach/detach` + `cp -r "$mnt"/*.app .` becomes a single `undmg "$src"` call (with `runHook preUnpack/postUnpack` per stdenv conventions).

If the implementer prefers to rely on undmg's setup-hook instead of a manual unpackPhase, they can drop the explicit `unpackPhase` block entirely. To check: after dropping it, `nix build .#cmux --no-link` should still succeed because the setup-hook auto-fires on `*.dmg`. If it fails (e.g. sourceRoot lands somewhere unexpected), restore the manual unpackPhase as above.

(`meta.platforms = platforms.darwin` is the existing claim — that's accurate; cmux really is darwin-only. Don't change to the supportedPlatforms pattern.)

- [ ] **Step 2.3: Rewrite the firefox overlay with assertion and PATH-resolved codesign**

Replace `overlays/firefox-binary-wrapper.nix` entirely with:

```nix
# Fix Firefox TCC permissions on macOS: use makeBinaryWrapper (compiled binary)
# instead of makeWrapper (bash script) so macOS attributes camera/mic
# permissions to "firefox" instead of "bash".
_: prev:
prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
  firefox = prev.firefox.overrideAttrs (
    oldAttrs:
    let
      sentinel = ''makeWrapper "$oldExe"'';
    in
    assert prev.lib.assertMsg (prev.lib.hasInfix sentinel oldAttrs.buildCommand) ''
      firefox-binary-wrapper overlay: upstream firefox buildCommand no longer
      contains the sentinel `${sentinel}`. The replaceStrings substitution would
      silently no-op, defeating the TCC permission fix. Re-audit nixpkgs'
      firefox wrapper and update this overlay.
    '';
    {
      nativeBuildInputs = oldAttrs.nativeBuildInputs ++ [
        prev.makeBinaryWrapper
        prev.darwin.sigtool
      ];
      buildCommand =
        builtins.replaceStrings [ sentinel ] [ ''makeBinaryWrapper "$oldExe"'' ] oldAttrs.buildCommand
        + ''
          # Re-sign the .app bundle so macOS binds Info.plist and sealed resources
          # (icon, bundle ID) to the binary wrapper for correct TCC icon display.
          # codesign requires Info.plist to be a regular file, not a symlink.
          appDir="$out/Applications/Firefox.app/Contents"
          if [ -L "$appDir/Info.plist" ]; then
            target=$(readlink -f "$appDir/Info.plist")
            rm -f "$appDir/Info.plist"
            cp -f "$target" "$appDir/Info.plist"
          fi
          codesign --force --sign - "$out/Applications/Firefox.app"
        '';
    }
  );
}
```

Three substantive changes:

1. Add `let sentinel = ''makeWrapper "$oldExe"''; in assert prev.lib.assertMsg (prev.lib.hasInfix sentinel oldAttrs.buildCommand) "...";` — fails the overlay at eval if upstream firefox ever stops emitting that string (B10).
2. Add `prev.darwin.sigtool` to `nativeBuildInputs` — provides a `codesign` shim on `PATH`.
3. Change `/usr/bin/codesign --force --sign -` to `codesign --force --sign -` — picks up sigtool's shim from PATH.

**Critical:** `prev.darwin.sigtool`, NOT `prev.sigtool`. The attribute lives under `pkgs.darwin.sigtool` in nixpkgs-26.05-darwin; bare `pkgs.sigtool` does not exist.

- [ ] **Step 2.4: Run `nix flake check --no-build` to verify eval succeeds (assert fires at eval time)**

```bash
nix flake check --no-build --show-trace
```

Expected: `all checks passed!`. If you see the assert message ("firefox-binary-wrapper overlay: upstream firefox buildCommand no longer..."), nixpkgs' firefox has changed shape — the implementer must re-audit upstream and update the sentinel.

- [ ] **Step 2.5: On a darwin host, build cmux to verify undmg works**

(Skip if implementer is on linux — the file is gated to darwin and the linux CI will exercise it post-merge only insofar as `nix flake check` already passed.)

```bash
nix build .#cmux --no-link
```

Expected: succeeds. Verify the `.app` ended up in the output:

```bash
ls -la "$(nix eval --raw .#cmux)/Applications/" | head -5
ls -la "$(nix eval --raw .#cmux)/bin/"
```

If `undmg` errors with "unsupported format" or "not a dmg", the dmg uses an APFS image undmg can't handle — fall back to `pkgs._7zz`:

```nix
{ lib, stdenvNoCC, fetchurl, _7zz }:
# ...
nativeBuildInputs = [ _7zz ];
unpackPhase = ''
  runHook preUnpack
  7zz x "$src" -o.
  runHook postUnpack
'';
```

Re-run `nix build .#cmux --no-link` to verify the fallback.

- [ ] **Step 2.6: Verify the firefox overlay's assertion fires when sentinel is wrong**

Temporarily test the assertion catches bad-sentinel cases:

```bash
cp overlays/firefox-binary-wrapper.nix /tmp/firefox-overlay-saved.nix
sed -i 's|sentinel = ''\''makeWrapper "\$oldExe"''\'';|sentinel = "BOGUSSENTINELNEVERMATCH";|' overlays/firefox-binary-wrapper.nix

nix eval --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    nixpkgs = builtins.getFlake "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    pkgs = import nixpkgs.outPath {
      system = "aarch64-darwin";
      overlays = [ flake.overlays.firefox-binary-wrapper ];
      config.allowUnfree = true;
    };
  in pkgs.firefox.outPath
' 2>&1 | tail -10
```

Expected: error message containing "firefox-binary-wrapper overlay: upstream firefox buildCommand no longer contains the sentinel `BOGUSSENTINELNEVERMATCH`". Confirms the assertion fires loudly.

Restore the file:

```bash
cp /tmp/firefox-overlay-saved.nix overlays/firefox-binary-wrapper.nix
rm /tmp/firefox-overlay-saved.nix
```

- [ ] **Step 2.7: Verify no `/usr/bin/` references remain in packages/ or overlays/**

```bash
grep -rn '/usr/bin/' packages/ overlays/
```

Expected: no output.

- [ ] **Step 2.8: Format and commit**

```bash
nix fmt  # if vault key error, use: nix fmt --builders '' --max-jobs 4
git add packages/cmux/default.nix overlays/firefox-binary-wrapper.nix
git status   # confirm only those two files changed
git commit -m "$(cat <<'EOF'
fix: replace /usr/bin/{hdiutil,codesign} with Nix-declared deps

cmux:
- Replace /usr/bin/hdiutil attach/cp/detach with `undmg "$src"`.
- Add undmg to granular signature + nativeBuildInputs.

firefox-binary-wrapper overlay:
- Add prev.darwin.sigtool to nativeBuildInputs (provides codesign shim).
- Switch /usr/bin/codesign to PATH-resolved `codesign`.
- Add B10 assertion: if upstream nixpkgs ever stops emitting the
  `makeWrapper "$oldExe"` sentinel in firefox's buildCommand, the
  overlay fails at eval rather than silently no-op-ing the TCC fix.

Sandbox-safety: both packages can now build under `sandbox = true`
without needing host-tool reachability. cmux/c9watch-{cli,gui}/firefox
remain darwin-gated so this is invisible to linux consumers.

Fixes deepdive findings S4 and B10.
EOF
)"
```

- [ ] **Step 2.9: Push the branch**

```bash
git push -u origin fix/host-tool-replacements
```

Do NOT run `gh run watch`. Do NOT open a PR.

- [ ] **Step 2.10: Report and stop — wait for human merge**

Report status DONE. The human will fast-forward `main` to this branch and push, triggering CI on the merge.

---

## Task 3: B3 — fix-lint rewrite + remove invalid-hash fallback in update-cmux.sh

**Why last:** B3 is the smallest unit; bundling it last means B2's potential `undmg` fallback didn't ripple. fix-lint and update-cmux.sh's S5 fix are disjoint from B1 and B2.

**Files:**

- Modify: `flake.nix` (`fix-lint` block — single attrset entry)
- Modify: `nix/update-cmux.sh` (drop `|| echo "sha256-$RAW"` fallback)

**Interfaces:**

- Consumes: post-B1+B2 state; no shared edits.
- Produces: `fix-lint` operates on `"$@"` (defaulting to `.`) at runtime, no store-path interpolation. `update-cmux.sh` fails hard on hash-conversion errors.

**Branch:** `fix/misc-correctness`

### Steps

- [ ] **Step 3.1: Create branch off updated origin/main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git fetch origin
git checkout -b fix/misc-correctness origin/main
git log --oneline origin/main -1
```

- [ ] **Step 3.2: Rewrite `fix-lint` in `flake.nix`**

Edit `flake.nix:96-98`. Replace:

```nix
            fix-lint = pkgs.writeShellScriptBin "fix-lint" ''
              ${lib.getExe pkgs.statix} fix ${./.}
            '';
```

With:

```nix
            fix-lint = pkgs.writeShellScriptBin "fix-lint" ''
              exec ${lib.getExe pkgs.statix} fix "''${@:-.}"
            '';
```

Two substantive changes:

1. `${./.}` (interpolates the flake source into the Nix store; statix can't write there) → `"''${@:-.}"` (positional args, default `.`).
2. Add `exec` to avoid an extra shell process.

Side effect (desired): `fix-lint`'s derivation now depends only on `pkgs.statix`, not on the entire repo source. Any file change in the repo no longer triggers a rebuild of `fix-lint`.

- [ ] **Step 3.3: Rewrite the hash-conversion fallback in `nix/update-cmux.sh`**

Edit `nix/update-cmux.sh:60-61`. Replace:

```bash
# Convert to SRI hash format (sha256-...)
LATEST_HASH_SRI=$(nix hash convert --hash-algo sha256 --to sri "$LATEST_HASH" 2>/dev/null || echo "sha256-$LATEST_HASH")
```

With:

```bash
# Convert to SRI hash format (sha256-...). Fail hard rather than write an
# invalid SRI string (deepdive S5).
LATEST_HASH_SRI=$(nix hash convert --hash-algo sha256 --to sri "$LATEST_HASH")
if [[ -z $LATEST_HASH_SRI ]]; then
  echo "  Error: nix hash convert failed for $LATEST_HASH" >&2
  exit 1
fi
```

Drop `2>/dev/null` so any nix-hash-convert error surfaces.

**Confirm `set -euo pipefail` is in scope.** Read the top of `nix/update-cmux.sh`. If `set -euo pipefail` (or at least `set -e`) is missing, add it near the top:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
# ...
```

(Task 1 already added `set -euo pipefail` to update-beads-web.sh and update-gascity.sh.)

- [ ] **Step 3.4: Verify `nix flake check --no-build` still passes**

```bash
nix flake check --no-build --show-trace
```

Expected: `all checks passed!`.

- [ ] **Step 3.5: Verify `fix-lint` runs against the working dir**

```bash
# Default — runs against current directory
nix run .#fix-lint
# Should exit 0 (no statix issues) or apply fixes in-place if any are found.

# Positional arg — runs against a specific subdir
nix run .#fix-lint -- packages/cmux
# Should exit 0 and only touch files under packages/cmux/.

# Multiple positional args
nix run .#fix-lint -- packages/cmux flake.nix
# Should statix-fix both targets.
```

- [ ] **Step 3.6: Verify `fix-lint`'s drv no longer embeds the repo source**

```bash
nix derivation show .#fix-lint | jq '.[].env.buildCommand' | grep -c '/nix/store/.*-source'
```

Expected: `0` (the build command no longer embeds a store path for the flake source). Compare to pre-change state (1 or more).

- [ ] **Step 3.7: Verify `update-cmux.sh` fails hard on bad hash input**

Synthetic test — give `nix hash convert` a malformed input by patching the script temporarily:

```bash
cp nix/update-cmux.sh /tmp/update-cmux-saved.sh

# Simulate the failure: make nix-prefetch-url return garbage
sed -i 's|LATEST_HASH=\$(nix-prefetch-url "\$DMG_URL" 2>/dev/null)|LATEST_HASH="not-a-real-hash"|' nix/update-cmux.sh

# Run — should print the error and exit 1 (NOT write "sha256-not-a-real-hash" anywhere)
./nix/update-cmux.sh "$(pwd)" 2>&1 | tail -3
echo "Exit code: $?"

# Restore
cp /tmp/update-cmux-saved.sh nix/update-cmux.sh
rm /tmp/update-cmux-saved.sh
```

Expected: error message "nix hash convert failed for not-a-real-hash" (or similar) and exit code 1. NOT a silent write of an invalid SRI string.

- [ ] **Step 3.8: Format and commit**

```bash
nix fmt  # if vault key error, use: nix fmt --builders '' --max-jobs 4
git add flake.nix nix/update-cmux.sh
git status   # confirm only those two files changed
git commit -m "$(cat <<'EOF'
fix(misc): fix-lint runs against $PWD; update-cmux fails hard

fix-lint (flake.nix):
- ${./.} (interpolates the flake source into the read-only store, where
  statix cannot write) becomes "''${@:-.}" — accepts any number of
  positional target dirs, defaults to current directory.
- exec avoids an extra shell process.
- Side effect: fix-lint's derivation no longer depends on the entire
  repo source. File changes no longer rebuild fix-lint.

update-cmux.sh (S5):
- Replace `nix hash convert ... || echo "sha256-$RAW"` invalid-SRI
  fallback with a hard fail. Previously, if `nix hash convert` errored,
  the script wrote a syntactically plausible but invalid sha256-<base32>
  string (SRI requires base64), causing the next build to fail with a
  confusing hash-mismatch error. Now fails loudly at update time.

Fixes deepdive findings B2 and S5 (update-cmux portion; beads-web and
gascity portions landed in Chunk 3 Branch 1).
EOF
)"
```

- [ ] **Step 3.9: Push the branch**

```bash
git push -u origin fix/misc-correctness
```

Do NOT run `gh run watch`. Do NOT open a PR.

- [ ] **Step 3.10: Report and stop — wait for human merge**

Report status DONE. The human will fast-forward `main` to this branch and push, triggering CI on the merge.

---

## Post-Chunk-3 Verification

After all three branches are merged, run this checklist:

- [ ] **Verify success criteria from the spec**

  ```bash
  # 1. No lib.fakeHash in packages/
  grep -RIn 'lib.fakeHash' packages/
  # Expected: no output

  # 2. meta.platforms is honest (just sanity-check beads-web and gascity)
  nix eval --json .#beads-web.meta.platforms
  nix eval --json .#gascity.meta.platforms
  # Expected: ["aarch64-darwin","x86_64-linux"] for each

  # 3. No /usr/bin/ references
  grep -rn '/usr/bin/' packages/ overlays/
  # Expected: no output

  # 4. Firefox overlay assert present
  grep -A2 'assertMsg' overlays/firefox-binary-wrapper.nix
  # Expected: matches the assert block

  # 5. fix-lint takes $@
  nix derivation show .#fix-lint | jq -r '.[].env.buildCommand' | grep '\${@'
  # Expected: matches

  # 6. Updater scripts fail hard (no `|| echo "sha256-` fallback)
  grep -n '|| echo "sha256-' nix/update-*.sh
  # Expected: no output

  # 7. Linux-exclusion filter gone
  grep -n 'removeAttrs self.packages' flake.nix
  # Expected: no output

  # 8. No c9watch references in code
  grep -RIn c9watch . --exclude-dir=.git --exclude-dir=docs --exclude=2026-06-12-nix-overlay-deepdive.md
  # Expected: no output

  # 9. CI on main green
  gh run list --branch=main --limit=1 --json conclusion --jq '.[0].conclusion'
  # Expected: success
  ```

- [ ] **Tell the user Chunk 3 is complete** and offer to proceed to Chunk 4 (README + gitignore hygiene) or pause.

---

## Rollback Reference

| Task        | Rollback command                                                                                                  |
| ----------- | ----------------------------------------------------------------------------------------------------------------- |
| Task 1 (B1) | `git revert <merge-sha>` on main. Restores c9watch via git history; fakeHash and meta.platforms overclaim return. |
| Task 2 (B2) | `git revert <merge-sha>` on main. Restores `/usr/bin/hdiutil` and `/usr/bin/codesign`.                            |
| Task 3 (B3) | `git revert <merge-sha>` on main. Restores broken fix-lint and the invalid-SRI fallback.                          |

Tasks are independently revertable; the changes don't cross-couple.

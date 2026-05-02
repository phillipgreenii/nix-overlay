# gascity Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Nix package derivation for the `gascity` Go CLI from `gastownhall/gascity`, exposed via `packages.${system}.gascity` and `overlays.default`, with a nightly auto-updater wired into `update-locks.sh`.

**Architecture:** Pre-built binary tarball downloaded from GitHub Releases, installed by a no-op `stdenvNoCC.mkDerivation`. Multi-platform via a `hashes` attrset keyed on Nix system identifiers (real SRI hashes for `aarch64-darwin` and `x86_64-linux`; `lib.fakeHash` placeholders for `x86_64-darwin` and `aarch64-linux`). The updater bumps `version` and any quoted hash entries by `sed`-rewriting the package file; unquoted `lib.fakeHash` placeholders are left untouched because the regex requires quoted values.

**Tech Stack:** Nix flakes, `stdenvNoCC.mkDerivation`, `fetchurl`, `pkgs.writeShellApplication`, GitHub Releases API, `nix-prefetch-url`, `sed`.

**Reference spec:** `docs/superpowers/specs/2026-05-02-gascity-package-design.md`

---

## File Structure

**Created:**
- `packages/gascity/default.nix` — the derivation. Inputs: `lib`, `pkgs`. Outputs: a derivation building `$out/bin/gc`. One responsibility: package the `gascity` release tarball.
- `nix/update-gascity.nix` — `pkgs.writeShellApplication` wrapper. Inputs: `pkgs`. Outputs: a Nix app named `update-gascity`. One responsibility: expose the updater script as a buildable Nix app with the right runtime PATH.
- `nix/update-gascity.sh` — the updater body. Argument: `$1` = repo root. Side effects: edits `packages/gascity/default.nix` in place. One responsibility: query GitHub releases, prefetch tarballs, rewrite version + hashes.

**Modified:**
- `flake.nix` — add three lines: `packages.gascity`, `apps.update-gascity`, and `gascity` in `overlays.default`'s always-on inherit list.
- `update-locks.sh` — add one `ul_run_step` invocation alongside the other GitHub-release package updaters, before `nix-flake-update`.

**Naming reminder (spec section 1):** Nix `pname = "gascity"`, but the installed binary is `gc` (matches upstream tarball and README). `meta.mainProgram = "gc"`.

---

## Task 1: Create the package derivation

**Files:**
- Create: `packages/gascity/default.nix`

- [ ] **Step 1: Write the derivation file**

Create `packages/gascity/default.nix` with the following content. Note the `hashes` attrset uses upstream asset suffixes as keys (`darwin_arm64`, etc.) to match the release URL pattern exactly. Real SRI hashes for `darwin_arm64` and `linux_amd64` were computed from the `v1.0.0` tarballs — they are pinned below.

```nix
{ lib, pkgs }:

let
  version = "1.0.0";

  platform =
    {
      aarch64-darwin = "darwin_arm64";
      x86_64-darwin = "darwin_amd64";
      x86_64-linux = "linux_amd64";
      aarch64-linux = "linux_arm64";
    }
    .${pkgs.stdenv.hostPlatform.system}
      or (throw "gascity: unsupported system ${pkgs.stdenv.hostPlatform.system}");

  hashes = {
    darwin_arm64 = "sha256-S2zb/9UotLKYUQj82OIS0m3s7uzHjkso+VoJx+MJFFk=";
    linux_amd64 = "sha256-zEXmvlTGuwD+aRWCn4vquyWlhbYEpHhGhFqnuacDcNM=";
    darwin_amd64 = lib.fakeHash;
    linux_arm64 = lib.fakeHash;
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "gascity";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/gastownhall/gascity/releases/download/v${version}/gascity_${version}_${platform}.tar.gz";
    hash =
      hashes.${platform}
        or (throw "gascity: no hash for ${platform}; run nix-prefetch-url on that platform");
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
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
```

- [ ] **Step 2: Wire into `flake.nix`**

Open `flake.nix`. In the always-on `packages` attrset (the block that contains `beads-web`, before the `lib.optionalAttrs pkgs.stdenv.isDarwin` block at around line 78), add this line alongside `beads-web`:

```nix
gascity = pkgs.callPackage ./packages/gascity { };
```

The result should look like (showing the relevant slice — keep all surrounding lines as-is):

```nix
packages = {
  beads-web = pkgs.callPackage ./packages/beads-web { };
  gascity = pkgs.callPackage ./packages/gascity { };
  tmux-open-nvim = pkgs.callPackage ./packages/tmux-open-nvim { };
  # ...rest unchanged...
};
```

- [ ] **Step 3: Build the package**

Run from the repo root:

```bash
nix build .#gascity
```

Expected: build succeeds (host is `x86_64-linux`, which has a real hash). Produces a `result/` symlink. If the build fails with a hash mismatch, that means upstream has changed the tarball — stop and re-prefetch.

- [ ] **Step 4: Verify the binary works**

Run:

```bash
./result/bin/gc version
```

Expected: prints a version banner mentioning `1.0.0` (or similar). The binary should be executable and at least not crash.

- [ ] **Step 5: Verify the binary path matches `mainProgram`**

Run:

```bash
test -x result/bin/gc && echo "gc binary present and executable"
ls result/bin/
```

Expected: `gc binary present and executable`, and `ls` shows exactly `gc` (not `gascity`).

- [ ] **Step 6: Commit**

```bash
git add packages/gascity/default.nix flake.nix
git commit -m "feat: add gascity package

Pre-built binary from gastownhall/gascity GitHub releases. Real SRI hashes
for aarch64-darwin and x86_64-linux; lib.fakeHash placeholders for the
other two supported platforms (fill in when needed).

Installs as bin/gc to match upstream README and Homebrew formula."
```

---

## Task 2: Add gascity to `overlays.default`

**Files:**
- Modify: `flake.nix` (the `overlays.default` block, around lines 102-119)

- [ ] **Step 1: Add `gascity` to the always-on inherit line**

In `flake.nix`, find the always-on inherit line in `overlays.default`:

```nix
inherit (ownPackages) beads-web bat-gherkin-syntax;
```

Change it to:

```nix
inherit (ownPackages) beads-web bat-gherkin-syntax gascity;
```

- [ ] **Step 2: Verify the overlay still evaluates**

Run from the repo root:

```bash
nix flake show 2>&1 | head -40
```

Expected: no errors; output lists `packages.x86_64-linux.gascity` and similar for the build platform. (Other-platform entries may show `omitted` or evaluation errors due to `fakeHash` — that is expected.)

- [ ] **Step 3: Verify the package is visible through the overlay**

Run:

```bash
nix eval --raw .#gascity.meta.mainProgram
```

Expected: prints `gc`.

- [ ] **Step 4: Commit**

```bash
git add flake.nix
git commit -m "feat: expose gascity through overlays.default

Lets downstream consumers using overlays.default access pkgs.gascity
without an explicit packages.\${system}.gascity reference."
```

---

## Task 3: Create the updater Nix wrapper

**Files:**
- Create: `nix/update-gascity.nix`

- [ ] **Step 1: Write the wrapper file**

Create `nix/update-gascity.nix` (exact mirror of `nix/update-cmux.nix`):

```nix
{ pkgs }:

pkgs.writeShellApplication {
  name = "update-gascity";

  runtimeInputs = [
    pkgs.curl
    pkgs.jq
    pkgs.gnused
    pkgs.nix
  ];

  text = builtins.readFile ./update-gascity.sh;
}
```

- [ ] **Step 2: Wire into `flake.nix` `apps`**

In `flake.nix`, find the `apps` block (around line 80-91). Add this line alongside the other `update-*` apps:

```nix
update-gascity = mkApp (pkgs.callPackage ./nix/update-gascity.nix { });
```

The result should look like:

```nix
apps =
  let
    mkApp = drv: { /* unchanged */ };
  in
  {
    update-cmux = mkApp (pkgs.callPackage ./nix/update-cmux.nix { });
    update-c9watch = mkApp (pkgs.callPackage ./nix/update-c9watch.nix { });
    update-beads-web = mkApp (pkgs.callPackage ./nix/update-beads-web.nix { });
    update-gascity = mkApp (pkgs.callPackage ./nix/update-gascity.nix { });
  };
```

- [ ] **Step 3: Verify Nix can evaluate the wrapper**

Run:

```bash
nix build .#update-gascity 2>&1 | tail -20
```

Expected: build fails because `./update-gascity.sh` does not yet exist. The error message should mention the missing file. (We will create it in Task 4.) **This failure is expected — proceed to commit.**

- [ ] **Step 4: Commit (allowing the broken state)**

This commit is intentionally broken on its own — it pairs with Task 4 to land the script. The TDD principle here is "create the slot first, then fill it" so the wiring is reviewable independently.

```bash
git add nix/update-gascity.nix flake.nix
git commit -m "feat: add update-gascity wrapper and wire into apps

Script body lands in the next commit; this commit isolates the Nix-side
wiring (apps entry + writeShellApplication wrapper) for clean review."
```

---

## Task 4: Implement the updater script

**Files:**
- Create: `nix/update-gascity.sh`

- [ ] **Step 1: Write the updater script**

Create `nix/update-gascity.sh` (modeled on `nix/update-beads-web.sh`):

```bash
# shellcheck shell=bash
# Update gascity package to latest GitHub release.
# Called from update-locks.sh before nix flake update.
#
# Checks GitHub for latest release, downloads each platform tarball to get
# its hash, and updates version and hashes in packages/gascity/default.nix
# if a newer release is available.
#
# Hash rewrites use a sed pattern that matches QUOTED hash values only
# (<key> = "..."). Lines like `darwin_amd64 = lib.fakeHash;` are unquoted
# and never match, so placeholders are left untouched until manually
# replaced with a real (or empty) quoted value.

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
echo "  Fetching artifact hashes (downloading ~20 MB per artifact)..."

DARWIN_ARM64_URL="https://github.com/gastownhall/gascity/releases/download/v${LATEST_VERSION}/gascity_${LATEST_VERSION}_darwin_arm64.tar.gz"
DARWIN_AMD64_URL="https://github.com/gastownhall/gascity/releases/download/v${LATEST_VERSION}/gascity_${LATEST_VERSION}_darwin_amd64.tar.gz"
LINUX_AMD64_URL="https://github.com/gastownhall/gascity/releases/download/v${LATEST_VERSION}/gascity_${LATEST_VERSION}_linux_amd64.tar.gz"
LINUX_ARM64_URL="https://github.com/gastownhall/gascity/releases/download/v${LATEST_VERSION}/gascity_${LATEST_VERSION}_linux_arm64.tar.gz"

RAW_DARWIN_ARM64=$(nix-prefetch-url "$DARWIN_ARM64_URL" 2>/dev/null)
[[ -z $RAW_DARWIN_ARM64 ]] && {
  echo "  Error: Could not prefetch $DARWIN_ARM64_URL" >&2
  exit 1
}
RAW_DARWIN_AMD64=$(nix-prefetch-url "$DARWIN_AMD64_URL" 2>/dev/null)
[[ -z $RAW_DARWIN_AMD64 ]] && {
  echo "  Error: Could not prefetch $DARWIN_AMD64_URL" >&2
  exit 1
}
RAW_LINUX_AMD64=$(nix-prefetch-url "$LINUX_AMD64_URL" 2>/dev/null)
[[ -z $RAW_LINUX_AMD64 ]] && {
  echo "  Error: Could not prefetch $LINUX_AMD64_URL" >&2
  exit 1
}
RAW_LINUX_ARM64=$(nix-prefetch-url "$LINUX_ARM64_URL" 2>/dev/null)
[[ -z $RAW_LINUX_ARM64 ]] && {
  echo "  Error: Could not prefetch $LINUX_ARM64_URL" >&2
  exit 1
}

HASH_DARWIN_ARM64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_DARWIN_ARM64" 2>/dev/null || echo "sha256-$RAW_DARWIN_ARM64")
HASH_DARWIN_AMD64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_DARWIN_AMD64" 2>/dev/null || echo "sha256-$RAW_DARWIN_AMD64")
HASH_LINUX_AMD64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_LINUX_AMD64" 2>/dev/null || echo "sha256-$RAW_LINUX_AMD64")
HASH_LINUX_ARM64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_LINUX_ARM64" 2>/dev/null || echo "sha256-$RAW_LINUX_ARM64")

echo "  Updating packages/gascity/default.nix..."
sed -i "s/version = \"$CURRENT_VERSION\";/version = \"$LATEST_VERSION\";/" "$TARGET"
sed -i "s|darwin_arm64 = \"[^\"]*\";|darwin_arm64 = \"$HASH_DARWIN_ARM64\";|" "$TARGET"
sed -i "s|darwin_amd64 = \"[^\"]*\";|darwin_amd64 = \"$HASH_DARWIN_AMD64\";|" "$TARGET"
sed -i "s|linux_amd64 = \"[^\"]*\";|linux_amd64 = \"$HASH_LINUX_AMD64\";|" "$TARGET"
sed -i "s|linux_arm64 = \"[^\"]*\";|linux_arm64 = \"$HASH_LINUX_ARM64\";|" "$TARGET"

echo "  ✓ gascity updated to $LATEST_VERSION"
```

- [ ] **Step 2: Verify the wrapper now builds**

Run:

```bash
nix build .#update-gascity
```

Expected: build succeeds. Produces a `result/bin/update-gascity` script.

- [ ] **Step 3: No-op run against current version**

The package file is at `1.0.0` (the latest at design time). Running the updater should report "up to date" and exit 0.

```bash
nix run .#update-gascity -- "$PWD"
```

Expected output (approximately):
```
Checking for gascity updates...
  Fetching latest release info...
  gascity is up to date (1.0.0)
```

Exit code: 0.

- [ ] **Step 4: Confirm no diff after no-op run**

```bash
git diff packages/gascity/default.nix
```

Expected: no output (file unchanged).

- [ ] **Step 5: Stale-version dry run — fakeHash lines are preserved**

This verifies the regex-based fakeHash skip behavior. Edit `packages/gascity/default.nix` to set `version = "0.0.0";` (a value guaranteed to be older than any real release), then run the updater:

```bash
sed -i 's/version = "1.0.0";/version = "0.0.0";/' packages/gascity/default.nix
nix run .#update-gascity -- "$PWD"
```

Expected: the script detects an update, downloads all four tarballs, and rewrites the file. Verify:

```bash
git diff packages/gascity/default.nix
```

Expected diff:
- `version = "0.0.0";` → `version = "1.0.0";` (or whatever current latest is).
- `darwin_arm64 = "sha256-..."` line refreshed (may be the same hash, may be different).
- `linux_amd64 = "sha256-..."` line refreshed.
- **Both `lib.fakeHash` lines (`darwin_amd64` and `linux_arm64`) MUST be unchanged** in the diff. If either is now `sha256-...`, the fakeHash-skip regex behavior is broken — stop and investigate.

- [ ] **Step 6: Reset the file to its committed state**

```bash
git checkout packages/gascity/default.nix
git diff packages/gascity/default.nix
```

Expected: second command produces no output.

- [ ] **Step 7: Commit**

```bash
git add nix/update-gascity.sh
git commit -m "feat: add gascity updater script

Modeled on update-beads-web.sh. Queries GitHub releases API, prefetches
all four platform tarballs, and sed-rewrites version + quoted hash entries
in packages/gascity/default.nix. Unquoted lib.fakeHash placeholders are
left untouched because the sed regex requires quoted values."
```

---

## Task 5: Wire updater into `update-locks.sh`

**Files:**
- Modify: `update-locks.sh` (around line 110)

- [ ] **Step 1: Add the `ul_run_step` invocation**

Open `update-locks.sh`. Find the `update-beads-web` step (around line 110-112):

```bash
ul_run_step "update-beads-web" \
  "update-locks: update beads-web" \
  nix run .#update-beads-web -- "${SCRIPT_DIR}"
```

Immediately after it, add:

```bash
ul_run_step "update-gascity" \
  "update-locks: update gascity" \
  nix run .#update-gascity -- "${SCRIPT_DIR}"
```

The result should be (showing the slice — keep surrounding steps as-is):

```bash
ul_run_step "update-beads-web" \
  "update-locks: update beads-web" \
  nix run .#update-beads-web -- "${SCRIPT_DIR}"

ul_run_step "update-gascity" \
  "update-locks: update gascity" \
  nix run .#update-gascity -- "${SCRIPT_DIR}"

ul_run_step "tmux-open-nvim" \
  "update-locks: update tmux-open-nvim" \
  update_tmux_plugin "tmux-open-nvim" "trevarj" "tmux-open-nvim" "master"
```

- [ ] **Step 2: Verify shellcheck passes**

The repo's pre-commit / treefmt config runs `shellcheck` against bash scripts. Run:

```bash
nix flake check 2>&1 | tail -40
```

Expected: no shellcheck errors related to `update-locks.sh`. (Other warnings unrelated to this change may appear — ignore those if they predate the edit.)

- [ ] **Step 3: Confirm the new step is recognized**

Inspect the script's step list by grepping the file:

```bash
grep -E '^ul_run_step "(update-|tmux-|bat-|nix-)' update-locks.sh
```

Expected: the output includes `ul_run_step "update-gascity"` between `update-beads-web` and `tmux-open-nvim`.

- [ ] **Step 4: Commit**

```bash
git add update-locks.sh
git commit -m "feat: run update-gascity from update-locks.sh

Placed between update-beads-web and the tmux-* steps, before
nix-flake-update — matches the ordering pattern of the other
GitHub-release package updaters."
```

---

## Task 6: Final verification

- [ ] **Step 1: Format check**

```bash
nix fmt
git diff
```

Expected: no diff. If the formatter changed anything, stage and commit those changes:

```bash
git add -u
git commit -m "style: treefmt on gascity package files"
```

- [ ] **Step 2: Full flake check**

```bash
nix flake check 2>&1 | tail -50
```

Expected: passes for the build platform's checks (formatting + linting). Build failures on other-platform `fakeHash` entries are expected and acceptable — they match `beads-web`'s current state.

- [ ] **Step 3: End-to-end build**

```bash
nix build .#gascity && ./result/bin/gc version
```

Expected: build succeeds; `gc version` prints a banner.

- [ ] **Step 4: Quick git log review**

```bash
git log --oneline -8
```

Expected: clean linear history showing the spec commit, the spec fix commit, and the five (or six, with formatting) implementation commits in order — no fixup commits, no reverts.

---

## Out-of-scope (do not do)

- **Do not** fill in real hashes for `x86_64-darwin` or `aarch64-linux`. The spec is explicit about leaving them as `lib.fakeHash`.
- **Do not** add a Home Manager module wrapping `gascity`. The repo's purpose is package derivations; an install-side module is out of scope.
- **Do not** add a unit test or `passthru.tests` derivation. This repo doesn't carry tests for derivations; the build itself is the contract.
- **Do not** symlink `$out/bin/gascity → gc` or otherwise add an alias. The upstream binary is `gc`, full stop.
- **Do not** add `gascity` to the `lib.optionalAttrs pkgs.stdenv.isDarwin` block. Linux is fully supported.

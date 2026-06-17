# Chunk 2: Overlay Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert all 9 `{ lib, pkgs }` package signatures to granular dependency arguments (A2), then invert `overlays.default` to use `final.callPackage` and re-derive `packages.${system}` from `pkgs.extend self.overlays.default` (A1).

**Architecture:** Two sequential branches off `main`. Branch 1 changes only package-file signatures — store paths unchanged. Branch 2 rewires the overlay so packages flow from the consumer's nixpkgs and `packages.${system}` becomes a thin re-export of the extended-pkgs view. Each branch is shippable on its own; together they realize deepdive findings A1 + A2.

**Tech Stack:** Nix flakes (nixpkgs-26.05-darwin), `flake-utils.lib.eachDefaultSystem`, the existing overlay/`callPackage` mechanism.

**Source spec:** `docs/superpowers/specs/2026-06-17-chunk2-overlay-architecture-design.md`
**Source review:** `2026-06-12-nix-overlay-deepdive.md` (findings A1, A2)

## Global Constraints

These apply to every task; the implementer must internalize them before starting.

- **Work in the worktree at `/home/tcadmin/workspace/nix-overlay-chunk1`.** The sibling main checkout at `/home/tcadmin/workspace/nix-overlay` is separate; do not cd there. `main` is checked out in the sibling — you cannot `git checkout main` in this worktree. Branch directly off `origin/main` with `git checkout -b <branch> origin/main`.
- **No pull requests.** Never run `gh pr create` / `gh pr merge` / `gh pr` of any kind. Your job ends with `git push`; the human merges to `main` locally and pushes.
- **CI does not run on feature branches.** `.github/workflows/ci.yml` triggers only on push-to-main and PRs-against-main. Do NOT run `gh run watch` — it hangs forever. Verification is local: `nix flake check --no-build --show-trace` plus per-package `nix build`.
- **Vault key infra issue.** The remote builder `192.168.2.53` has been failing on derivations requiring `/run/vault-secrets/nix-signing-key.sec`. If `nix fmt` (or any other `nix` command) fails with "No such file or directory" for that path, retry the command with `--builders '' --max-jobs 4` to force local execution.
- **Do NOT fix B5/B6/S4 inline.** `lib.fakeHash` placeholders, dishonest `meta.platforms`, and `/usr/bin/{hdiutil,codesign}` host-tool references stay exactly as they are. Those are Chunk 3 territory; Chunk 2 only changes function signatures and overlay wiring.
- **Don't touch the Chunk 1 Task 3 linux-exclusion filter** (`removeAttrs ... ["beads-web" "gascity"]` inside the `checks =` block at `flake.nix`). It still works as written.
- **Don't touch `apps`, `legacyPackages`, `homeModules`, `overlays.firefox-binary-wrapper`, or the dev-shell utility packages (`fix-lint`, `install-pre-commit-hooks`)** — out of scope.

## Preconditions

1. The spec branch `docs/chunk2-overlay-architecture-spec` (which also contains this plan) has been merged into `main` and pushed. Implementation branches branch from the post-merge main so the docs travel with the code.
2. Worktree exists at `/home/tcadmin/workspace/nix-overlay-chunk1` with the docs branch checked out.
3. The post-Chunk-1 main is at or after commit `649f2f1`. `nix-checks (ubuntu-latest)` and `nix-checks (macos-latest)` are required status checks on `main`.

---

## Task 1: A2 — Convert all 9 package files to granular dependency arguments

**Why first:** Mechanical, low risk. `pkgs.callPackage` accepts either `{ lib, pkgs }` or granular signatures; A2 is store-path-neutral until A1 rewires the overlay. Shippable on its own.

**Files:**
- Modify: `packages/bat-gherkin-syntax/default.nix:1`
- Modify: `packages/beads-web/default.nix:1, 12, 13, 21, 25, 39`
- Modify: `packages/cmux/default.nix:1, 2, 6`
- Modify: `packages/gascity/default.nix:1, 13, 23, 27`
- Modify: `packages/tmux-open-nvim/default.nix:1, 2, 5`
- Modify: `packages/tmux-mouse-swipe/default.nix:1, 2, 5`
- Modify: `packages/tmux-nerd-font-window-name/default.nix:1, 2, 5`
- Modify: `packages/c9watch/cli.nix:1, 10, 21, 25`
- Modify: `packages/c9watch/gui.nix:1, 10, 21, 25`

**Interfaces:**
- Consumes: nothing from prior tasks.
- Produces: each package file now declares the exact deps it imports. Branch 2's overlay calls `final.callPackage <path> { }` and relies on the file's `__functionArgs` driving dependency injection. The deps shipped by Branch 1 must include every attr the body references.

**Branch:** `refactor/granular-package-deps`

### Steps

- [ ] **Step 1.1: Create branch off updated origin/main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git fetch origin
git checkout -b refactor/granular-package-deps origin/main
git log --oneline origin/main -1
```

Expected: clean checkout, last commit on origin/main is at or after `649f2f1` (post-Chunk-1).

**Note on Steps 1.2–1.10:** The nine file edits are independent — each touches one file with no cross-references. They may be done in any order. (Subagent-driven workflows could even parallelize them, but verification Step 1.11 only makes sense once all nine are done.)

- [ ] **Step 1.2: Edit `packages/bat-gherkin-syntax/default.nix`**

Replace line 1:

```nix
{ lib, pkgs }:
```

With:

```nix
{ lib, fetchFromGitHub }:
```

Then substitute occurrences in the body: replace `pkgs.fetchFromGitHub` with `fetchFromGitHub` (one site, line 3). The file's full post-edit content should be:

```nix
{ lib, fetchFromGitHub }:
# last updated: unstable-2024-10-12
fetchFromGitHub {
  owner = "keith-hall";
  repo = "SublimeGherkinSyntax";
  rev = "ec3fae90209136a89a5027f61167e04790c83382";
  sha256 = "sha256-yYIMfzAiKdQsl3OPSevENsrs4TkNe+eVVPSRbtHagNY=";
  meta = {
    platforms = lib.platforms.unix;
  };
}
```

(The `rev` and `sha256` were pinned in Chunk 1 Task 2 — if those values differ from what's currently in the file, the file has been updated by the nightly bot since this plan was written; preserve the *current* values in the file rather than the ones shown here. Use Edit with targeted substitutions; do NOT pass the full block to Write.)

- [ ] **Step 1.3: Edit `packages/beads-web/default.nix`**

Replace line 1:

```nix
{ lib, pkgs }:
```

With:

```nix
{ lib, stdenv, fetchurl }:
```

Substitute in the body:
- Line 12: `pkgs.stdenv.hostPlatform.system` → `stdenv.hostPlatform.system`
- Line 13: same substitution
- Line 21: `pkgs.stdenv.mkDerivation` → `stdenv.mkDerivation`
- Line 25: `pkgs.fetchurl` → `fetchurl`
- Line 39: `with pkgs.lib;` → `with lib;` (incidental B9 hit — `lib` is already in scope; using `pkgs.lib` was redundant)

Full post-edit content:

```nix
{ lib, stdenv, fetchurl }:

let
  version = "0.11.2";

  platform =
    {
      aarch64-darwin = "darwin-arm64";
      x86_64-darwin = "darwin-x64";
      x86_64-linux = "linux-x64";
    }
    .${stdenv.hostPlatform.system}
      or (throw "beads-web: unsupported system ${stdenv.hostPlatform.system}");

  hashes = {
    darwin-arm64 = "sha256-6+4ddKilgMHFfSBSNCQNPl2jZDmNtWpQ99zKn2bWnkc=";
    darwin-x64 = lib.fakeHash;
    linux-x64 = lib.fakeHash;
  };
in
stdenv.mkDerivation {
  pname = "beads-web";
  inherit version;

  src = fetchurl {
    url = "https://github.com/weselow/beads-web/releases/download/v${version}/beads-web-${platform}";
    hash =
      hashes.${platform}
        or (throw "beads-web: no hash for ${platform}; run nix-prefetch-url on that platform");
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
    platforms = platforms.unix;
  };
}
```

(`lib.fakeHash` and `meta.platforms = platforms.unix` stay — they're B5/B6 territory, addressed in Chunk 3.)

- [ ] **Step 1.4: Edit `packages/cmux/default.nix`**

Replace line 1:

```nix
{ lib, pkgs }:
```

With:

```nix
{ lib, stdenvNoCC, fetchurl }:
```

Substitute in the body:
- Line 2: `pkgs.stdenvNoCC.mkDerivation` → `stdenvNoCC.mkDerivation`
- Line 6: `pkgs.fetchurl` → `fetchurl`

Lines 15 and 17 (`/usr/bin/hdiutil ...`) **stay exactly as-is** — string literals referencing the host tool. S4 territory; Chunk 3.

Full post-edit content:

```nix
{ lib, stdenvNoCC, fetchurl }:
stdenvNoCC.mkDerivation rec {
  pname = "cmux";
  version = "0.64.16";

  src = fetchurl {
    url = "https://github.com/manaflow-ai/cmux/releases/download/v${version}/cmux-macos.dmg";
    hash = "sha256-QB/2emBrAzqkcKaLrVUZanK4qXHSma4CeJM2PwGhmXI=";
  };

  nativeBuildInputs = [ ];

  unpackPhase = ''
    mnt=$(mktemp -d)
    /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$src"
    cp -r "$mnt"/*.app .
    /usr/bin/hdiutil detach "$mnt"
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

- [ ] **Step 1.5: Edit `packages/gascity/default.nix`**

Replace line 1:

```nix
{ lib, pkgs }:
```

With:

```nix
{ lib, stdenv, stdenvNoCC, fetchurl }:
```

Substitute in the body:
- Line 13: `pkgs.stdenv.hostPlatform.system` → `stdenv.hostPlatform.system`
- Line 23: `pkgs.stdenvNoCC.mkDerivation` → `stdenvNoCC.mkDerivation`
- Line 27: `pkgs.fetchurl` → `fetchurl`

Full post-edit content:

```nix
{ lib, stdenv, stdenvNoCC, fetchurl }:

let
  version = "1.2.1";

  platform =
    {
      aarch64-darwin = "darwin_arm64";
      x86_64-darwin = "darwin_amd64";
      x86_64-linux = "linux_amd64";
      aarch64-linux = "linux_arm64";
    }
    .${stdenv.hostPlatform.system}
      or (throw "gascity: unsupported system ${stdenv.hostPlatform.system}");

  hashes = {
    darwin_arm64 = "sha256-xJ82ow1PdV0VSRI/ufx5NNwApf7BeffUBI0UF2pfD6s=";
    linux_amd64 = "sha256-erwm2CaIHTghlgDiXnigo2gC7d+ebtdwRidfXsnnIXI=";
    darwin_amd64 = lib.fakeHash;
    linux_arm64 = lib.fakeHash;
  };
in
stdenvNoCC.mkDerivation {
  pname = "gascity";
  inherit version;

  src = fetchurl {
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

- [ ] **Step 1.6: Edit `packages/tmux-open-nvim/default.nix`**

Replace line 1:

```nix
{ lib, pkgs }:
```

With:

```nix
{ lib, tmuxPlugins, fetchFromGitHub }:
```

Substitute in the body:
- Line 2: `pkgs.tmuxPlugins.mkTmuxPlugin` → `tmuxPlugins.mkTmuxPlugin`
- Line 5: `pkgs.fetchFromGitHub` → `fetchFromGitHub`

Full post-edit content:

```nix
{ lib, tmuxPlugins, fetchFromGitHub }:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-open-nvim";
  version = "unstable-2026-04-20";
  src = fetchFromGitHub {
    owner = "trevarj";
    repo = "tmux-open-nvim";
    rev = "d140ac66e24f1cd26b68638da01a82717a1921bd";
    sha256 = "sha256-lftDhRERenGVDTWFP1o/bfZIk0RsHh2PxoYY8j8/9CQ=";
  };
  meta = {
    platforms = lib.platforms.unix;
  };
}
```

(If the file's current `rev`/`sha256` differ from what's shown — e.g. the nightly bot ran since this plan was written — preserve the file's current values rather than the values shown here. Use Edit with targeted substitutions; do NOT pass the full block to Write.)

- [ ] **Step 1.7: Edit `packages/tmux-mouse-swipe/default.nix`**

Same shape as Step 1.6. Replace line 1 with `{ lib, tmuxPlugins, fetchFromGitHub }:`, then substitute `pkgs.tmuxPlugins.mkTmuxPlugin` → `tmuxPlugins.mkTmuxPlugin` (line 2) and `pkgs.fetchFromGitHub` → `fetchFromGitHub` (line 5). Preserve `rev`, `sha256`, and the rest.

Full post-edit content:

```nix
{ lib, tmuxPlugins, fetchFromGitHub }:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-mouse-swipe";
  version = "unstable-2025-12-29";
  src = fetchFromGitHub {
    owner = "jaclu";
    repo = "tmux-mouse-swipe";
    rev = "8667851876c7591c668f29df6a142271051a3e2d";
    sha256 = "sha256-0Mh0sQm3GP1V/KlYi6VjD3Zx2ssLwVI5uOnOp67trYk=";
  };
  meta = {
    platforms = lib.platforms.unix;
  };
}
```

(Preserve the file's current `rev`/`sha256` if they've drifted from these via nightly bot updates. Use Edit, not Write.)

- [ ] **Step 1.8: Edit `packages/tmux-nerd-font-window-name/default.nix`**

Same shape as Step 1.6. Full post-edit content:

```nix
{ lib, tmuxPlugins, fetchFromGitHub }:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-nerd-font-window-name";
  version = "unstable-2026-04-10";
  src = fetchFromGitHub {
    owner = "joshmedeski";
    repo = "tmux-nerd-font-window-name";
    rev = "0af812a228e1b9f538b8d220c6c59d82d7228973";
    sha256 = "sha256-b6CQdN33hU5li/0LUOHMs7oN8ffVRVQlSf17Twhz2e8=";
  };
  meta = {
    platforms = lib.platforms.unix;
  };
}
```

(Preserve the file's current `rev`/`sha256` if drifted from these. Use Edit, not Write.)

- [ ] **Step 1.9: Edit `packages/c9watch/cli.nix`**

Replace line 1:

```nix
{ lib, pkgs }:
```

With:

```nix
{ lib, stdenv, stdenvNoCC, fetchurl }:
```

Substitute in the body:
- Line 10: `pkgs.stdenv.hostPlatform.system` → `stdenv.hostPlatform.system`
- Line 21: `pkgs.stdenvNoCC.mkDerivation` → `stdenvNoCC.mkDerivation`
- Line 25: `pkgs.fetchurl` → `fetchurl`

Full post-edit content:

```nix
{ lib, stdenv, stdenvNoCC, fetchurl }:
let
  version = "0.8.1";

  arch =
    {
      aarch64-darwin = "aarch64";
      x86_64-darwin = "x86_64";
    }
    .${stdenv.hostPlatform.system}
      or (throw "c9watch: unsupported system ${stdenv.hostPlatform.system}");

  cliHashAarch64 = "sha256-eoPZVa6C5obU+n2htn3buhdHPRsQtlECjl4MFby6bY8=";
  cliHashX86_64 = "sha256-sNhu818VAosCWX7BKEXJunwuVeBloFzQ0EOFg6VhNYc=";

  cliHashes = {
    aarch64 = cliHashAarch64;
    x86_64 = cliHashX86_64;
  };
in
stdenvNoCC.mkDerivation {
  pname = "c9watch-cli";
  inherit version;

  src = fetchurl {
    url = "https://github.com/minchenlee/c9watch/releases/download/v${version}/c9watch-cli-${arch}-apple-darwin.tar.gz";
    hash = cliHashes.${arch};
  };

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/bin
    install -m755 c9watch $out/bin/c9watch
  '';

  meta = with lib; {
    description = "CLI companion for c9watch monitoring dashboard";
    homepage = "https://github.com/minchenlee/c9watch";
    license = licenses.mit;
    platforms = platforms.darwin;
  };
}
```

- [ ] **Step 1.10: Edit `packages/c9watch/gui.nix`**

Same dep additions as Step 1.9. Substitute on lines 10, 21, 25. Line 37's `/usr/bin/codesign ...` stays as a string literal (S4 territory).

Full post-edit content:

```nix
{ lib, stdenv, stdenvNoCC, fetchurl }:
let
  version = "0.8.1";

  arch =
    {
      aarch64-darwin = "aarch64";
      x86_64-darwin = "x86_64";
    }
    .${stdenv.hostPlatform.system}
      or (throw "c9watch: unsupported system ${stdenv.hostPlatform.system}");

  guiHashAarch64 = "sha256-o++hhIR5LeWcuFH34twVcQTVfWdrtqtHiZpN7g1hBnI=";
  guiHashX86_64 = "sha256-Zy/ggj9l+Cf3MC0kVa732lKD/7sZRhIjmulZLFOfo80=";

  guiHashes = {
    aarch64 = guiHashAarch64;
    x86_64 = guiHashX86_64;
  };
in
stdenvNoCC.mkDerivation {
  pname = "c9watch";
  inherit version;

  src = fetchurl {
    url = "https://github.com/minchenlee/c9watch/releases/download/v${version}/c9watch_v${version}_${arch}.app.tar.gz";
    hash = guiHashes.${arch};
  };

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/Applications
    cp -r c9watch.app $out/Applications/
    chmod +x "$out/Applications/c9watch.app/Contents/MacOS/c9watch"
    /usr/bin/codesign --force --deep --sign - "$out/Applications/c9watch.app"
  '';

  meta = with lib; {
    description = "Real-time monitoring dashboard for Claude Code sessions";
    homepage = "https://github.com/minchenlee/c9watch";
    license = licenses.mit;
    platforms = platforms.darwin;
  };
}
```

- [ ] **Step 1.11: Verify `nix flake check --no-build` evaluates cleanly**

```bash
nix flake check --no-build --show-trace
```

Expected: `all checks passed!` with no "function called without required argument 'X'" errors. If you see one, the new signature is missing a dep — add it and retry.

- [ ] **Step 1.12: Build linux-buildable packages locally to verify granular deps work**

```bash
nix build .#tmux-open-nvim --no-link
nix build .#tmux-mouse-swipe --no-link
nix build .#tmux-nerd-font-window-name --no-link
nix build .#bat-gherkin-syntax --no-link
```

Each must succeed. (`beads-web` and `gascity` are excluded from linux builds per Chunk 1 Task 3, but you can spot-check eval: `nix eval --raw .#beads-web.drvPath` should not error.)

If on a darwin host, also try:
```bash
nix build .#cmux --no-link
nix build .#c9watch-cli --no-link
nix build .#c9watch-gui --no-link
```

- [ ] **Step 1.13: Verify `__functionArgs` exposes the granular deps for a sample package**

```bash
nix eval --json --impure --expr 'builtins.functionArgs (import ./packages/tmux-open-nvim/default.nix)'
```

Expected: `{"fetchFromGitHub":false,"lib":false,"tmuxPlugins":false}` (the booleans indicate "not a defaultable argument"). Confirms the granular signature is in place.

- [ ] **Step 1.14: Format and commit**

```bash
nix fmt  # if vault key error, use: nix fmt --builders '' --max-jobs 4
git add packages/
git status   # confirm only files under packages/ changed
git commit -m "refactor(packages): destructure granular dependencies

Convert all nine package files from { lib, pkgs } whole-pkgs injection to
granular dependency arguments (fetchurl, fetchFromGitHub, stdenv,
stdenvNoCC, tmuxPlugins). Restores callPackage's per-dep injection and
lets consumers swap individual inputs via .override.

The yaziPlugins set already used granular args; this brings the other
nine files in line.

Incidental: drop \`with pkgs.lib;\` in beads-web meta in favor of the
in-scope \`with lib;\` (deepdive B9 nit).

Out of scope (deferred to Chunk 3): the lib.fakeHash placeholders, the
dishonest meta.platforms claims, and the /usr/bin/{hdiutil,codesign}
host-tool string literals.

Fixes deepdive finding A2.
"
```

- [ ] **Step 1.15: Push the branch**

```bash
git push -u origin refactor/granular-package-deps
```

Do NOT run `gh run watch`. Do NOT open a PR.

- [ ] **Step 1.16: Report and stop — wait for human merge**

Report status DONE (or DONE_WITH_CONCERNS if anything noteworthy). The human will fast-forward `main` to `refactor/granular-package-deps` and push, triggering CI on the merge.

---

## Task 2: A1 — Invert overlay; re-derive `packages.${system}` from extended pkgs

**Why second:** Depends on Task 1 (granular deps are what makes the inversion meaningful). Once landed, every package flows from the consumer's nixpkgs through one canonical wiring.

**Files:**
- Modify: `flake.nix:63-89` (the `packages = { ... }` block — replace whole-block)
- Modify: `flake.nix:114-134` (the `overlays.default = ...` block — replace whole-block)

**Interfaces:**
- Consumes from Task 1: every `packages/<name>/default.nix` declares its real deps via `{ lib, stdenv?, stdenvNoCC?, fetchurl?, fetchFromGitHub?, tmuxPlugins?, ... }`.
- Produces: `pkgs.extend self.overlays.default` evaluates to a pkgs-like set with `beads-web`, `bat-gherkin-syntax`, `gascity`, the three tmux plugins under `tmuxPlugins.*`, `yaziPlugins.{icons-brew,bunny}`, plus darwin-only `cmux`, `c9watch-{gui,cli}` — all built against the consumer's nixpkgs via `final.callPackage`.

**Branch:** `refactor/invert-overlay`

### Steps

- [ ] **Step 2.1: Create branch off updated origin/main**

```bash
cd /home/tcadmin/workspace/nix-overlay-chunk1
git fetch origin
git checkout -b refactor/invert-overlay origin/main
git log --oneline origin/main -1
```

The current `origin/main` HEAD must include the Task 1 commit (`refactor: destructure granular dependencies` or similar). Confirm with `git log --oneline -5`.

- [ ] **Step 2.2: Rewire `overlays.default` to use `final.callPackage`**

Edit `flake.nix:114-134`. Replace the entire `overlays.default = ...` block:

Find:

```nix
      overlays.default =
        final: prev:
        let
          ownPackages = self.packages.${prev.stdenv.hostPlatform.system};
        in
        {
          inherit (ownPackages) beads-web bat-gherkin-syntax gascity;
          tmuxPlugins = prev.tmuxPlugins // {
            inherit (ownPackages)
              tmux-open-nvim
              tmux-mouse-swipe
              tmux-nerd-font-window-name
              ;
          };
          yaziPlugins = prev.yaziPlugins // (
            let ours = final.callPackage ./packages/yaziPlugins { };
            in { inherit (ours) icons-brew bunny; }
          );
        }
        // prev.lib.optionalAttrs prev.stdenv.isDarwin {
          inherit (ownPackages) cmux c9watch-gui c9watch-cli;
        };
```

Replace with:

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

Changes:
- The `let ownPackages = self.packages.${...}; in` binding is gone.
- Every `inherit (ownPackages) X` becomes `X = final.callPackage ./packages/X { };`.
- The yaziPlugins clause is unchanged (Chunk 1 Task 1 already did it right).
- `prev.stdenv.isDarwin` (deprecated) is replaced with `prev.stdenv.hostPlatform.isDarwin` (the same incidental B9 nit Chunk 1 already used for top-level `pkgs.stdenv.isDarwin` in the `packages =` block — keep them consistent).

**Critical:** the overlay function body must NOT reference `self` or `self.packages` anywhere. Step 2.3 derives `packages.${system}` from `pkgs.extend self.overlays.default` — if the overlay reaches back to `self.packages`, the cycle becomes `packages → extended → overlay → self.packages → packages` and Step 2.4 fails with "infinite recursion encountered." If your edit accidentally reintroduces any `self.X` reference inside the overlay function body, remove it.

- [ ] **Step 2.3: Re-derive `packages.${system}` from `pkgs.extend self.overlays.default`**

Edit `flake.nix:63-89`. Replace the entire `packages = { ... };` block:

Find:

```nix
        packages = {
          beads-web = pkgs.callPackage ./packages/beads-web { };
          gascity = pkgs.callPackage ./packages/gascity { };
          tmux-open-nvim = pkgs.callPackage ./packages/tmux-open-nvim { };
          tmux-mouse-swipe = pkgs.callPackage ./packages/tmux-mouse-swipe { };
          tmux-nerd-font-window-name = pkgs.callPackage ./packages/tmux-nerd-font-window-name { };
          bat-gherkin-syntax = pkgs.callPackage ./packages/bat-gherkin-syntax { };

          yaziPlugins-icons-brew = yaziPluginSet.icons-brew;
          yaziPlugins-bunny = yaziPluginSet.bunny;

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
          cmux = pkgs.callPackage ./packages/cmux { };
          c9watch-gui = pkgs.callPackage ./packages/c9watch/gui.nix { };
          c9watch-cli = pkgs.callPackage ./packages/c9watch/cli.nix { };
        };
```

Replace with:

```nix
        packages =
          let
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
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            inherit (extended) cmux c9watch-gui c9watch-cli;
          };
```

Changes:
- Wrap the block in `let extended = pkgs.extend self.overlays.default; in`.
- Replace every `pkgs.callPackage ./packages/X { }` with `inherit (extended) X;` (grouped for top-level, and via `inherit (extended.tmuxPlugins) X;` for the three tmux plugins).
- `yaziPlugins-icons-brew` and `yaziPlugins-bunny` source from `extended.yaziPlugins.{icons-brew,bunny}` instead of `yaziPluginSet`.
- `fix-lint` and `install-pre-commit-hooks` stay sourced from `pkgs` — they're dev tooling, not overlay packages.
- The `// lib.optionalAttrs pkgs.stdenv.isDarwin { ... }` becomes `// lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin { inherit (extended) cmux c9watch-gui c9watch-cli; };` — both the deprecation fix and the sourcing change.

**Note (`yaziPluginSet` double-eval, accepted):** after this change, `yaziPluginSet` (defined at `flake.nix:43`) is still referenced by `legacyPackages.yaziPlugins` (at `flake.nix:105-109`, written by Chunk 1 Task 1). That means the yaziPlugins set is evaluated twice — once for `yaziPluginSet`, once via the overlay. Spec marks `legacyPackages` as out of scope for Chunk 2, so this is *accepted* as a minor cost. A future chunk can rewire `legacyPackages.yaziPlugins` to source from `extended` and delete the `yaziPluginSet` binding.

- [ ] **Step 2.4: Run `nix flake check --no-build` to verify eval succeeds**

```bash
nix flake check --no-build --show-trace
```

Expected: `all checks passed!`. If you see "infinite recursion encountered" — `self.overlays.default` referenced from `packages` while the overlay references `self.packages` somewhere — re-check Step 2.2 (the overlay should not reference `ownPackages` or `self.packages` anywhere).

- [ ] **Step 2.5: Build representative packages locally**

```bash
nix build .#bat-gherkin-syntax --no-link
nix build .#tmux-open-nvim --no-link
nix build .#yaziPlugins-icons-brew --no-link
```

All three must succeed. Do NOT build `beads-web` / `gascity` on linux here — they're already excluded from CI by the Chunk 1 Task 3 filter (Step 2.8 verifies the exclusion). Eval-check them instead to prove the overlay wires them at least:

```bash
nix eval --raw .#beads-web.drvPath 2>&1 | head -2
nix eval --raw .#gascity.drvPath  2>&1 | head -2
```

Each should print a `/nix/store/...drv` path. If you see "attribute missing" or "function called without required argument", the overlay wiring is broken — re-check Step 2.2.

- [ ] **Step 2.6: Consumer-side overlay test (proves A1 took effect)**

```bash
nix eval --raw --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    nixpkgs = builtins.getFlake "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    pkgs = import nixpkgs.outPath {
      system = builtins.currentSystem;
      overlays = [ flake.overlays.default ];
    };
  in pkgs.bat-gherkin-syntax.outPath
'
```

Expected: a `/nix/store/...` path. This proves the overlay applied cleanly to an externally-imported nixpkgs and that consumers can reach our packages via `pkgs.bat-gherkin-syntax`. Also try the namespaced ones:

```bash
nix eval --raw --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    nixpkgs = builtins.getFlake "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    pkgs = import nixpkgs.outPath {
      system = builtins.currentSystem;
      overlays = [ flake.overlays.default ];
    };
  in pkgs.tmuxPlugins.tmux-open-nvim.outPath
'
```

Expected: a `/nix/store/...` path. Confirms the `prev.tmuxPlugins //` merge worked.

- [ ] **Step 2.7: Override-granularity check (proves A1 + A2 together)**

Two checks. First the signature check on the raw file (proves A2 took effect — the granular signature is in place):

```bash
nix eval --json --expr 'builtins.attrNames (builtins.functionArgs (import ./packages/bat-gherkin-syntax/default.nix))'
```

Expected: `["fetchFromGitHub","lib"]`. (No `--impure` needed; pure Nix eval against a fixed file path.)

Then the overlay-flow check (proves A1 plumbs the granular signature through the consumer's pkgs — `.override` is a `makeOverridable`-flavored function whose `functionArgs` matches the package's signature):

```bash
nix eval --json --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    nixpkgs = builtins.getFlake "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    pkgs = import nixpkgs.outPath {
      system = builtins.currentSystem;
      overlays = [ flake.overlays.default ];
    };
  in builtins.functionArgs pkgs.bat-gherkin-syntax.override
'
```

Expected: a JSON object whose keys include `lib` and `fetchFromGitHub`. If `pkgs.bat-gherkin-syntax.override` doesn't exist (some fetchers don't carry `.override`), substitute `pkgs.tmux-open-nvim.override` or `pkgs.beads-web.override` — those go through `stdenv.mkDerivation` which always gets `makeOverridable`.

- [ ] **Step 2.8: Verify Chunk 1 Task 3 linux exclusions still work**

```bash
nix eval .#checks.x86_64-linux.beads-web 2>&1 | head -3
nix eval .#checks.x86_64-linux.gascity 2>&1 | head -3
nix eval --raw .#checks.x86_64-linux.bat-gherkin-syntax.outPath
nix eval --raw .#checks.x86_64-linux.tmux-open-nvim.outPath
```

Expected: first two error with "attribute 'X' missing" (correctly excluded); last two print `/nix/store/...` paths (correctly included).

- [ ] **Step 2.9: Format and commit**

```bash
nix fmt  # if vault key error, use: nix fmt --builders '' --max-jobs 4
git add flake.nix
git status   # confirm only flake.nix changed
git commit -m "refactor(flake): invert overlay; derive packages from extended pkgs

Rewire overlays.default to build each package via final.callPackage (the
consumer's nixpkgs). Re-derive packages.\${system} from
pkgs.extend self.overlays.default so the overlay and the flake-output
packages share a single source of truth.

Before: packages.\${system} called pkgs.callPackage against this flake's
locked nixpkgs, and overlays.default re-exported them via
inherit (self.packages.\${system}) ... . Consumers applying the overlay
got our nixpkgs eval, not theirs — losing override granularity and
forcing two nixpkgs evaluations per consumer.

After: overlays.default is the source of truth; packages.\${system}
imports the same derivations via pkgs.extend. Consumer overrides via
.override (now meaningful thanks to Chunk 2 Task 1's granular signatures)
flow through naturally.

Incidental: stdenv.isDarwin -> stdenv.hostPlatform.isDarwin (deepdive B9
nit, applied to the two sites this change touched).

Fixes deepdive finding A1.
"
```

- [ ] **Step 2.10: Push the branch**

```bash
git push -u origin refactor/invert-overlay
```

Do NOT run `gh run watch`. Do NOT open a PR.

- [ ] **Step 2.11: Report and stop — wait for human merge**

Report status DONE. The human will fast-forward `main` to `refactor/invert-overlay` and push, triggering CI on the merge.

---

## Post-Chunk-2 Verification

After both branches are merged, run this checklist:

- [ ] **Verify success criteria** (from spec section "Success Criteria"):

  ```bash
  # 1. No { lib, pkgs } signatures remain
  grep -lE '^\{\s*lib,\s*pkgs\s*\}:' packages/**/*.nix
  # Expected: no output

  # 2. overlays.default uses final.callPackage; no self.packages references
  grep 'self.packages' flake.nix | grep -v '^\s*#'
  # Expected: only references inside the `extended = pkgs.extend self.overlays.default` line in packages =
  grep 'ownPackages' flake.nix
  # Expected: no output

  # 3. packages.<system> derived from extended
  grep -A1 'extended = pkgs.extend' flake.nix
  # Expected: matches

  # 4. Consumer overlay test (from Step 2.6) succeeds
  # Run that command — must print a /nix/store/... path

  # 5. Override-granularity test (from Step 2.7) succeeds
  # Run that command — must print { ... } JSON of granular args

  # 6. CI on main is green
  gh run list --branch=main --limit=1 --json conclusion --jq '.[0].conclusion'
  # Expected: success
  ```

- [ ] **Tell the user Chunk 2 is complete** and offer to proceed to Chunk 3 (honesty/correctness: B5/B6 fakeHash, S4 host tools, B2 fix-lint, B10 firefox overlay assertion).

---

## Rollback Reference

| Task | Rollback command |
|---|---|
| Task 1 (A2) | `git revert <merge-sha>` on main |
| Task 2 (A1) | `git revert <merge-sha>` on main |

Note: rolling back Task 2 while keeping Task 1 is safe (`pkgs.callPackage` accepts granular signatures, just doesn't use override granularity). Rolling back Task 1 alone is also safe as long as Task 2 hasn't landed yet.

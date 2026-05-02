# Design: `gascity` package

**Status**: Approved
**Date**: 2026-05-02
**Author**: Phillip Green II

## Summary

Add a third-party package derivation for [gastownhall/gascity](https://github.com/gastownhall/gascity) — a Go CLI distributed as platform tarballs on GitHub Releases. The derivation installs the pre-built binary, supports four platforms (`aarch64-darwin`, `x86_64-darwin`, `x86_64-linux`, `aarch64-linux`), is exposed via both `packages.${system}.gascity` and `overlays.default`, and is kept current by a nightly auto-updater wired into `update-locks.sh`. The shape mirrors the existing `beads-web` package precedent.

## Motivation

This repo (per `docs/adr/0001-purpose-of-this-repo.md`) is the consolidation point for third-party Nix derivations the author needs in personal/work Nix configurations. `gascity` is not in `nixpkgs` and has no upstream Nix flake; the natural home is here.

## Non-goals

- Building from source via `buildGoModule`. Gascity ships pre-built binaries; using them is faster and matches the rest of the overlay.
- A Home Manager / NixOS module wrapping the package (no `programs.gascity.enable`, no service unit, no managed config). The repo's purpose is package derivations only; an install-side module is out of scope.
- Real hashes for every platform on day one. Only the platforms the author currently uses get real hashes; the rest are `lib.fakeHash` placeholders that can be filled in later.

## Architecture

### Components

1. **`packages/gascity/default.nix`** — the derivation.
2. **`nix/update-gascity.nix`** — `pkgs.writeShellApplication` wrapper exposing the updater as a Nix app.
3. **`nix/update-gascity.sh`** — the updater script body.
4. **`flake.nix`** — three small additions: `packages.gascity`, `apps.update-gascity`, and `gascity` in `overlays.default`.
5. **`update-locks.sh`** — one new `ul_run_step` invocation calling `nix run .#update-gascity`.

### Data flow

- **Build path**: consumer (this flake or a downstream flake using `overlays.default`) requests `pkgs.gascity` → `callPackage ./packages/gascity { }` resolves the platform, looks up the SRI hash, `fetchurl` downloads the release tarball, `installPhase` extracts the `gascity` binary into `$out/bin`.
- **Update path**: `update-locks.sh` (nightly via GitHub Actions, daily at `0 11 * * *`) invokes `nix run .#update-gascity -- "$REPO_ROOT"` → script queries GitHub releases API for `tag_name`, exits early if unchanged, otherwise `nix-prefetch-url`s each release tarball and `sed`-rewrites the `version` field and the per-platform hash entries in `packages/gascity/default.nix`. Then `nix flake update` runs as the final step.

## Detailed design

### 1. `packages/gascity/default.nix`

Modeled directly on `packages/beads-web/default.nix`.

- `pname = "gascity"`, `version` set to the latest release at commit time (`1.0.0` initially).
- `platform` is selected via attrset lookup keyed on `pkgs.stdenv.hostPlatform.system`, mapping to the suffix used in upstream release asset names:

  | Nix system          | Upstream asset suffix |
  |---------------------|----------------------|
  | `aarch64-darwin`    | `darwin_arm64`       |
  | `x86_64-darwin`     | `darwin_amd64`       |
  | `x86_64-linux`      | `linux_amd64`        |
  | `aarch64-linux`     | `linux_arm64`        |

  Unsupported systems `throw` with an explanatory message, matching `beads-web`.

- `hashes` attrset keyed by the same suffixes:
  - `darwin_arm64`: real SRI hash (computed at implementation time).
  - `linux_amd64`: real SRI hash.
  - `darwin_amd64`: `lib.fakeHash`.
  - `linux_arm64`: `lib.fakeHash`.

- Source URL: `https://github.com/gastownhall/gascity/releases/download/v${version}/gascity_${version}_${platform}.tar.gz`.

- Builder: `pkgs.stdenvNoCC.mkDerivation` (no compile step). `sourceRoot = "."`, `dontFixup = true` — same idiom as `c9watch-cli` for tarballed pre-built binaries.

- `installPhase`:
  ```sh
  mkdir -p $out/bin
  install -m755 gascity $out/bin/gascity
  ```

- `meta`:
  - `description = "Orchestration-builder SDK for multi-agent systems"`.
  - `homepage = "https://github.com/gastownhall/gascity"`.
  - `license = licenses.mit`.
  - `mainProgram = "gascity"`.
  - `platforms = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ]`.

### 2. `nix/update-gascity.nix`

Exact mirror of `nix/update-cmux.nix`:

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

### 3. `nix/update-gascity.sh`

Modeled on `update-beads-web.sh`. Behavior:

- Takes `REPO_ROOT` as `$1`, defaults to `.`. Targets `${REPO_ROOT}/packages/gascity/default.nix`.
- Reads `CURRENT_VERSION` via the established `grep 'version = ' | head -1 | sed` idiom.
- `curl`s `https://api.github.com/repos/gastownhall/gascity/releases/latest`, extracts `tag_name`, strips a leading `v`. Sends `Authorization: Bearer $GH_TOKEN` if set (avoids GitHub API rate limits in CI).
- Early-exits with success if `CURRENT_VERSION == LATEST_VERSION`.
- For each platform suffix (`darwin_arm64`, `darwin_amd64`, `linux_amd64`, `linux_arm64`):
  - `nix-prefetch-url`s the release asset.
  - Converts to SRI via `nix hash convert`.
  - `sed`-replaces the corresponding line in the package file using the pattern `<suffix> = "[^"]*";`.
- Updates the top-level `version` field with `sed`.

**Skipping `fakeHash` placeholders comes for free**: the `sed` regex requires a *quoted* hash value (`"[^"]*"`). Lines like `darwin_amd64 = lib.fakeHash;` are unquoted and never match the substitution, so they remain untouched without any explicit detection logic. This matches the existing behavior of `update-beads-web.sh` against the current `beads-web` file, which has two `lib.fakeHash` placeholders.

The updater still calls `nix-prefetch-url` for every platform's tarball (uniform behavior, matches `update-beads-web.sh`), even though the resulting hash for `fakeHash`-flagged platforms goes unused. If those tarballs are missing from the release, the script fails fast — same failure mode as `beads-web`. (If this becomes a problem later, the script can be tightened to skip prefetching for `fakeHash` platforms; out of scope for now.)

### 4. `flake.nix` edits

Three additions, each one line:

1. In the always-on `packages` attrset (alongside `beads-web`, before the `lib.optionalAttrs pkgs.stdenv.isDarwin` block):
   ```nix
   gascity = pkgs.callPackage ./packages/gascity { };
   ```

2. In the `apps` attrset:
   ```nix
   update-gascity = mkApp (pkgs.callPackage ./nix/update-gascity.nix { });
   ```

3. In `overlays.default`, in the always-on `inherit (ownPackages) ...` line:
   ```nix
   inherit (ownPackages) beads-web bat-gherkin-syntax gascity;
   ```

No new flake inputs. No changes to `treefmt.nix`, pre-commit configuration, or `lib/`.

### 5. `update-locks.sh` edits

Add one `ul_run_step` invocation alongside the other `update-<pkg>` steps and **before** the `nix-flake-update` step:

```bash
ul_run_step "update-gascity" \
  "update-locks: update gascity" \
  nix run .#update-gascity -- "${SCRIPT_DIR}"
```

Placement: after `update-beads-web` and before the `tmux-*` steps (alphabetical-ish grouping with the other GitHub-release packages).

## Error handling

Inherits the patterns of the existing updaters and derivations:

- **Unsupported system at build time**: derivation `throw`s with a message naming the system.
- **Missing release asset at build time**: `fetchurl` fails with the upstream URL in the error message.
- **`fakeHash` mismatch at build time**: build fails with the standard "got hash X expected Y" Nix error, surfacing the real hash for the operator to copy in.
- **GitHub API failure in updater**: script `exit 1` with an error message; `ul_run_step` reports the failure in the per-step git history without aborting subsequent steps (existing behavior).
- **`nix-prefetch-url` failure in updater**: script `exit 1` with the failing URL.

## Testing & verification

- `nix build .#gascity` succeeds on the build host's platform; resulting `result/bin/gascity` is executable and prints a help/version banner.
- `nix flake check` passes formatting (`treefmt`) and linting (`statix`) on the new files. Builds on platforms with `fakeHash` placeholders will fail — expected, matches `beads-web`.
- `nix run .#update-gascity -- "$PWD"` against an unchanged repo prints "up to date" and exits 0.
- `nix run .#update-gascity -- "$PWD"` after manually setting `version` to a stale value bumps it back and updates the real-hash entries; the `lib.fakeHash` lines are unchanged in the diff.
- No unit tests added — this repo's contract is the build itself.

## Alternatives considered

### Build from source via `buildGoModule`

**Rejected**: every other GitHub-release package in this repo (`cmux`, `beads-web`, `c9watch-cli`, `c9watch-gui`) uses pre-built artifacts. `buildGoModule` would pull in the Go toolchain at build time and require maintaining a `vendorHash` alongside the source hash. Pre-built binary is faster, simpler, and consistent.

### Skip the auto-updater; bump versions by hand

**Rejected**: every other GitHub-release package in this repo has an updater wired into `update-locks.sh` and the nightly workflow. Skipping it would silently let `gascity` go stale and break the established maintenance pattern.

### Add a Home Manager module wrapping the package

**Rejected** (option C in brainstorming). The repo's stated purpose is package derivations only; the only existing `homeModules` entry is metadata-only. A wrapper module is out of scope and can be added downstream (in `phillipgreenii-nix-personal` or similar) if/when the author wants managed config.

### Real hashes for every platform on day one

**Rejected** (option B in brainstorming on platform support). Two real hashes (`aarch64-darwin`, `x86_64-linux`) cover the platforms the author actively uses; placeholder hashes for the other two avoid prefetch work for unused platforms and match the established `beads-web` precedent. Real hashes can be filled in any time by editing the file or running the updater after replacing a placeholder with `""` and rebuilding to capture the expected hash from the error.

## Out-of-scope follow-ups

- Filling in real hashes for `x86_64-darwin` and `aarch64-linux` when the author starts using those platforms.
- Adding a Home Manager module wrapping `gascity` config (in a downstream personal/work repo, not here).
- Documenting `gascity` usage in any consumer repo's README.

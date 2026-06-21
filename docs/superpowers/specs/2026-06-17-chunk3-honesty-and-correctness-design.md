# Chunk 3: Honesty & Correctness — Design

**Date:** 2026-06-17
**Source review:** [`2026-06-12-nix-overlay-deepdive.md`](../../../2026-06-12-nix-overlay-deepdive.md)
**Findings addressed:** B5 (dishonest meta.platforms), B6 (updaters that prefetch but don't write fakeHash), S4 (impure host-tool usage), B10 (firefox overlay silent-no-op), B2 (fix-lint broken), S5 (invalid-hash fallback). Plus c9watch removal (housekeeping).
**Estimated effort:** ~90 min implementation + CI cycles

## Goal

Stop lying. Every package's `meta.platforms` reflects platforms that actually build. Every host-tool string literal (`/usr/bin/hdiutil`, `/usr/bin/codesign`) is replaced with a proper Nix dependency. `fix-lint` operates on the working directory at runtime instead of a frozen store path. The updaters fail hard on hash-conversion errors instead of writing syntactically-plausible-but-invalid SRI strings. c9watch is removed since it's no longer used.

The user's cross-platform constraint shapes which platforms we keep and which we drop: **match-current-usage-only** — aarch64-darwin (the user's MacBook) + x86_64-linux (the homelab NixOS host). Anything else gets a clean `meta.platforms` rejection instead of `lib.fakeHash` or a `throw`.

## Non-Goals

- Re-add platforms we're dropping (darwin-x64, linux_arm64, darwin_amd64) — defer to a hypothetical future user need.
- Bring c9watch back — it's deleted, not deprecated.
- Touch the bootstrap-disconnected `nix run nixpkgs#nix-prefetch-github` pattern in `update-locks.sh` (Chunk 1 Task 4 disposition stays).
- Touch Chunk 2's overlay/granular-deps wiring (out of scope).
- Touch the branch protection rule on main (Chunk 1 Task 5; immutable here).
- Adopt nvfetcher — that's Chunk 5.

## Workflow

Three local branches off `main`, each pushed to `origin` for human-merge. **No PRs opened.** CI workflow only triggers on push-to-main / PR-against-main, so per-branch CI is not available — verification is local via `nix flake check` and per-package `nix build`. CI runs after the human merges to main.

All work in the worktree `/home/tcadmin/workspace/nix-overlay-chunk1`. Branches off `origin/main` (currently `74e77a6`, post-Chunk-2).

## Branch Order

```
B1 ──► B2 ──► B3
honesty       host tools     misc
+ c9watch     S4 + B10       B2 + S5
removal       (cmux+firefox) (fix-lint, updater)
B5 + B6
```

- **B1 first** because it removes c9watch (eliminating one of the two `/usr/bin/codesign` users B2 would otherwise have to touch) and because B5/B6 drops the Chunk-1-Task-3 linux-exclusion filter — both ground-clearing moves.
- **B2 second** is the structural host-tool replacement work; depends on B1's c9watch removal to keep its scope tight.
- **B3 last** because B2 might surface unrelated issues (undmg/dmg compatibility) the implementer should resolve before B3's misc work piles on.
- **B2 and B3 may be executed in either order after B1** if wall-clock parallelism is preferred — they touch disjoint files (B2: `packages/cmux/default.nix`, `overlays/firefox-binary-wrapper.nix`; B3: `flake.nix` fix-lint block, the 3 updater scripts). The serial chain reduces merge-skew risk only.

---

## Branch 1 — `fix/drop-c9watch-and-honest-platforms` (B5 + B6 + c9watch removal)

### Problem

- **c9watch unused:** User dropped it locally; the overlay still packages it, exports it, downloads its release artifacts nightly. Dead weight + dead supply-chain surface.
- **B5 (dishonest meta.platforms):** `packages/beads-web/default.nix:45` and `packages/gascity/default.nix:47-52` claim platforms they can't actually build. Forcing the derivation on those platforms throws at eval (`throw "beads-web: unsupported system ..."`) instead of giving a clean "not available on this platform" error.
- **B6 (updaters don't write fakeHash):** `nix/update-beads-web.sh:73-75` and `nix/update-gascity.sh:85-88` sed-substitute only quoted hash values (`<key> = "..."`). `lib.fakeHash` is unquoted (`darwin-x64 = lib.fakeHash;`), so the seds never match and the placeholder lingers forever. The updaters downloaded those platforms (~10-20 MB each) and threw the resulting hash away.
- **Chunk-1-Task-3 linux-exclusion filter leftover:** `flake.nix:58-66` removes `beads-web` and `gascity` from linux checks. After honest hashes land, the filter is dead code.

### Change

**c9watch removal:**

- Delete: `packages/c9watch/cli.nix`, `packages/c9watch/gui.nix`, `packages/c9watch/` (the directory should be empty after removing both files).
- Delete: `nix/update-c9watch.sh`, `nix/update-c9watch.nix`.
- `flake.nix`:
  - Line 107: remove `c9watch-gui c9watch-cli` from `inherit (extended) ... ;` (the darwin block in `packages`).
  - Lines 163-164: remove `c9watch-gui = ...;` and `c9watch-cli = ...;` from the overlay's darwin block.
  - Line 125: remove the `update-c9watch = mkApp ...;` line.
- `update-locks.sh`: remove the `ul_run_step "update-c9watch" ...` block.

**beads-web honest platforms (`packages/beads-web/default.nix`):**

Pattern (nixpkgs convention for prebuilt-binary fetchers): collapse the parallel `platform = { ... }.${...}` and `hashes = { ... }` maps into a single `supportedPlatforms` attrset; derive `meta.platforms` from its keys so they can't drift. Keep the `throw` for unsupported platforms — it's the standard nixpkgs pattern for binary fetchers (terraform, slack, obsidian all do this).

Target state (replacing the current `platform = ...` and `hashes = ...` blocks):

```nix
{ lib, stdenv, fetchurl }:

let
  version = "0.11.2";

  supportedPlatforms = {
    aarch64-darwin = {
      artifact = "darwin-arm64";
      hash = "sha256-6+4ddKilgMHFfSBSNCQNPl2jZDmNtWpQ99zKn2bWnkc=";
    };
    x86_64-linux = {
      artifact = "linux-x64";
      hash = "sha256-eDL5aAwQ41XK58YFirf7HLvImxR5PJeFr6WIzmS5IRE=";
    };
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

Honesty wins (over the current state):

- `meta.platforms` is `[ "aarch64-darwin" "x86_64-linux" ]` — exactly the platforms that build. No more `platforms.unix` overclaim.
- `lib.fakeHash` is gone.
- `meta.platforms` is derived from `supportedPlatforms` keys — they cannot drift.
- The throw message names the actual supported platforms instead of just "unsupported system".

The throw still fires on `nix eval .#beads-web.drvPath` on an unsupported system — that's identical to nixpkgs convention for prebuilt-binary packages (`pkgs.terraform`, `pkgs.kubectl`). Build attempts via `nix build`, `nix-env -i`, or home-manager all consult `meta.platforms` first and reject cleanly before forcing the throw.

The `sha256-eDL5aAwQ41XK58YFirf7HLvImxR5PJeFr6WIzmS5IRE=` value above was computed against the current release at the time this spec was written. If the upstream version bumps between spec and implementation, re-derive with:

```bash
nix store prefetch-file --json --hash-type sha256 \
  "https://github.com/weselow/beads-web/releases/download/v<NEW-VERSION>/beads-web-linux-x64" \
  | jq -r .hash
```

(Use `nix store prefetch-file` rather than `nix-prefetch-url | xargs nix hash convert` — it emits SRI directly and avoids the stderr "path is …" noise.)

**gascity honest platforms (`packages/gascity/default.nix`):**

Same restructure pattern. Final state:

```nix
supportedPlatforms = {
  aarch64-darwin = {
    artifact = "darwin_arm64";
    hash = "sha256-xJ82ow1PdV0VSRI/ufx5NNwApf7BeffUBI0UF2pfD6s=";
  };
  x86_64-linux = {
    artifact = "linux_amd64";
    hash = "sha256-erwm2CaIHTghlgDiXnigo2gC7d+ebtdwRidfXsnnIXI=";
  };
};
```

Drop `darwin_amd64` and `linux_arm64` entirely. `meta.platforms = builtins.attrNames supportedPlatforms;` instead of the hand-rolled 4-element list.

**Updater script reflows (B6):**

**Critical: the `supportedPlatforms` entries must be written as one-line attrset literals so sed can target each platform's hash unambiguously.** The multi-line form (shown above for spec readability) becomes one line per platform when actually written to file:

```nix
supportedPlatforms = {
  aarch64-darwin = { artifact = "darwin-arm64"; hash = "sha256-6+4ddKilgMHFfSBSNCQNPl2jZDmNtWpQ99zKn2bWnkc="; };
  x86_64-linux   = { artifact = "linux-x64";    hash = "sha256-eDL5aAwQ41XK58YFirf7HLvImxR5PJeFr6WIzmS5IRE="; };
};
```

This shape lets each platform's hash be rewritten with a single anchored sed (one per platform), no cross-contamination.

`nix/update-beads-web.sh`:

- Drop the `DARWIN_X64_URL` prefetch + hash computation (lines 48, 56-60, 68, 74).
- Update lines 47-75 to handle only the two supported platforms.
- Update the seds at lines 73-75 to target the new one-line attrset shape. For each platform, anchor on the system-name key:
  ```bash
  sed -i "s|aarch64-darwin = { artifact = \"darwin-arm64\"; hash = \"[^\"]*\"; };|aarch64-darwin = { artifact = \"darwin-arm64\"; hash = \"$HASH_DARWIN_ARM64\"; };|" "$TARGET"
  sed -i "s|x86_64-linux\s*= { artifact = \"linux-x64\"; hash = \"[^\"]*\"; };|x86_64-linux   = { artifact = \"linux-x64\"; hash = \"$HASH_LINUX_X64\"; };|" "$TARGET"
  ```

`nix/update-gascity.sh`:

- Drop the `DARWIN_AMD64_URL` and `LINUX_ARM64_URL` prefetches + hash computations (lines 53-55, 62-66, 72-76, 79, 81, 86, 88).
- Update remaining seds to target the same one-line attrset shape (artifacts `darwin_arm64` / `linux_amd64`).

**Why one-line over multi-line + range-addressed sed:** range-addressed sed (`sed -i "/aarch64-darwin = {/,/};/ s|hash = ...|...|"`) works but is brittler — `nix fmt` may reformat across runs, breaking the address pattern. One-line entries are nixfmt-stable.

**flake.nix cleanup:**

Remove the `// (if pkgs.stdenv.hostPlatform.isLinux then removeAttrs ... else ...)` filter at `flake.nix:58-66`. After honest platforms, `checks` simplifies to:

```nix
checks = {
  formatting = treefmtEval.config.build.check self;
  linting = checks-lib.linting ./.;
} // self.packages.${system};
```

### Verification

1. `nix flake check --no-build --show-trace` exits 0.
2. `nix build .#beads-web --no-link` on linux succeeds (was hash-mismatch before).
3. `nix build .#gascity --no-link` on linux succeeds.
4. `nix build .#beads-web .#gascity --system aarch64-darwin --dry-run` on linux: emits the expected darwin builds without throw.
5. On linux: `nix eval .#packages.aarch64-linux.beads-web` _throws_ with the "not supported; build platforms: ..." message (the standard nixpkgs pattern for prebuilt-binary packages — `pkgs.terraform`, `pkgs.kubectl`, `pkgs.obsidian` all do the same). `nix-build`/`nix build`/home-manager consult `meta.platforms` before forcing the throw, so user-facing install attempts get a clean rejection. The throw only surfaces on direct eval-time access to the derivation (e.g. `nix flake show --json` across all systems).
6. `grep c9watch flake.nix update-locks.sh nix/ packages/` returns no matches.
7. After merge, the post-merge CI on `main` exercises every package on its declared platforms with no exclusion filter.

### Risk / Rollback

- **Real hash for beads-web linux-x64:** must be computed for the current release. If the release tag changes between writing this spec and execution, recompute.
- **Updater script shape change:** the sed patterns must match the new attribute layout. Test on a synthetic version bump.
- **Rollback:** `git revert` returns to fakeHash-era; doesn't restore c9watch's files (those are gone). If c9watch needs to come back, restore from git history.

---

## Branch 2 — `fix/host-tool-replacements` (S4 + B10)

### Problem

- `packages/cmux/default.nix:15, 17` call `/usr/bin/hdiutil attach/detach` — works on darwin only because the darwin sandbox is commonly off. With `sandbox = true` (Determinate Nix's stricter defaults), it fails. Mount leaks on `cp` failure (no trap).
- `overlays/firefox-binary-wrapper.nix:21` calls `/usr/bin/codesign`. Same impurity story.
- B10: `overlays/firefox-binary-wrapper.nix:9` uses `builtins.replaceStrings [ ''makeWrapper "$oldExe"'' ] ...` against `oldAttrs.buildCommand`. If nixpkgs ever stops emitting that exact string, `replaceStrings` silently substitutes nothing and the entire overlay becomes a no-op — Firefox loses its TCC permission fix invisibly.

### Change

**cmux (`packages/cmux/default.nix`):**

Replace the `/usr/bin/hdiutil` dance:

```nix
unpackPhase = ''
  mnt=$(mktemp -d)
  /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$src"
  cp -r "$mnt"/*.app .
  /usr/bin/hdiutil detach "$mnt"
'';
```

With `undmg`:

```nix
nativeBuildInputs = [ undmg ];
unpackPhase = ''
  runHook preUnpack
  undmg "$src"
  runHook postUnpack
'';
```

Signature change: `{ lib, stdenvNoCC, fetchurl, undmg }`.

**Alternative (simpler):** `undmg` ships a setup-hook (`pkgs/by-name/un/undmg/setup-hook.sh`) that auto-fires on `*.dmg` sources. Just adding `undmg` to `nativeBuildInputs` lets stdenv's default `unpackPhase` invoke the hook. The manual `unpackPhase` block above is only needed if the implementer wants to keep it explicit (matches repo style) or if `sourceRoot` doesn't land where `installPhase` expects. **Verify against the actual dmg empirically:** if the existing `sourceRoot = ".";` and `installPhase`'s `cp -r *.app $out/Applications/` find the `.app` after extraction, the manual unpackPhase can be dropped; otherwise keep it.

`undmg` is in nixpkgs-26.05-darwin for darwin systems; cmux is gated to darwin so no linux-eval concern. If undmg fails on this specific dmg (APFS image), the implementer falls back to `pkgs._7zz`:

```nix
nativeBuildInputs = [ _7zz ];
unpackPhase = ''
  runHook preUnpack
  7zz x "$src" -o.
  runHook postUnpack
'';
```

Signature would be `{ lib, stdenvNoCC, fetchurl, _7zz }` in that fallback. Decision made empirically by trying `undmg` first.

**firefox-binary-wrapper (`overlays/firefox-binary-wrapper.nix`):**

Final shape:

```nix
# Fix Firefox TCC permissions on macOS: use makeBinaryWrapper (compiled binary)
# instead of makeWrapper (bash script) so macOS attributes camera/mic
# permissions to "firefox" instead of "bash".
_: prev:
prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
  firefox = prev.firefox.overrideAttrs (oldAttrs:
    let
      sentinel = ''makeWrapper "$oldExe"'';
    in
    assert prev.lib.assertMsg
      (prev.lib.hasInfix sentinel oldAttrs.buildCommand)
      ''
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
        builtins.replaceStrings [ sentinel ] [ ''makeBinaryWrapper "$oldExe"'' ]
          oldAttrs.buildCommand
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
    });
}
```

Changes:

- Add `prev.darwin.sigtool` to `nativeBuildInputs`. **Important:** the attribute path is `pkgs.darwin.sigtool`, not `pkgs.sigtool` (which doesn't exist in nixpkgs-26.05-darwin). The package realises a `codesign` shim into `$out/bin/codesign`.
- `/usr/bin/codesign --force --sign -` → `codesign --force --sign -` (PATH-resolved via `nativeBuildInputs`).
- Add `assert prev.lib.assertMsg (prev.lib.hasInfix sentinel oldAttrs.buildCommand) "..."` so an upstream nixpkgs change to firefox's `buildCommand` shape fails the overlay at eval rather than silently producing a no-op.
- Sentinel hoisted to a let-binding to keep the assert message and the replaceStrings input in sync.

### Verification

1. `nix flake check --no-build --show-trace` exits 0 (the assert evaluates at flake-check time).
2. On darwin: `nix build .#cmux --no-link` succeeds. Confirms `undmg` unpacked cmux's dmg correctly. If it fails with "unsupported dmg format", retry with `_7zz`.
3. On darwin: `nix build firefox` (with the overlay applied) succeeds. Confirms `sigtool` codesigns correctly + assertion passes against current nixpkgs.
4. Sanity-check the assert fires: temporarily swap the sentinel for a string definitely not in the firefox buildCommand (`sentinel = "BOGUS";`). `nix eval --raw .#cmux` should error with the assert's message. Restore.
5. `grep "/usr/bin/" packages/ overlays/` returns no matches.

### Risk / Rollback

- `undmg` may not handle cmux's specific dmg. Fallback to `_7zz`.
- The assertion is conservative — if nixpkgs ever reformats the buildCommand without changing semantics, the overlay breaks loudly until updated. Acceptable: forcing a manual re-audit is the point.
- Rollback: `git revert`. Firefox falls back to the impure `/usr/bin/codesign` path; cmux falls back to hdiutil.

---

## Branch 3 — `fix/misc-correctness` (B2 + S5)

### Problem

- **B2 (`fix-lint` broken):** `flake.nix:96-98` defines `fix-lint = pkgs.writeShellScriptBin "fix-lint" '' ${lib.getExe pkgs.statix} fix ${./.} '';`. `${./.}` interpolates the flake source _into the store_; `statix fix` cannot write there. Every file change in the repo also rebuilds the trivial script (the whole repo is its build input).
- **S5 (invalid-hash fallback):** `nix/update-{beads-web,cmux,gascity}.sh` have `nix hash convert ... 2>/dev/null || echo "sha256-$RAW"`. If `nix hash convert` ever fails (older nix, PATH issue), the fallback writes `sha256-<base32>` — a syntactically plausible SRI string but actually invalid base64. Gets committed; the next build fails opaquely.

### Change

**fix-lint (`flake.nix`):**

```nix
fix-lint = pkgs.writeShellScriptBin "fix-lint" ''
  exec ${lib.getExe pkgs.statix} fix "''${@:-.}"
'';
```

Changes:

- `${./.}` → `"''${@:-.}"` — accepts any number of target paths as positional args, or defaults to `$PWD` if none. `statix fix` accepts multiple positional targets.
- Add `exec` to avoid an extra shell process.
- Drop the repo-as-build-input dependency (the script's hash depends only on `pkgs.statix`).

Examples after fix:

- `nix run .#fix-lint` → `statix fix .`
- `nix run .#fix-lint -- packages/cmux` → `statix fix packages/cmux`
- `nix run .#fix-lint -- packages/cmux flake.nix` → `statix fix packages/cmux flake.nix`

**S5 fallback removal in updater scripts (`nix/update-beads-web.sh`, `nix/update-cmux.sh`, `nix/update-gascity.sh`):**

Replace every:

```bash
HASH_X=$(nix hash convert --hash-algo sha256 --to sri "$RAW_X" 2>/dev/null || echo "sha256-$RAW_X")
```

With (two-statement form — see "Why two statements" below):

```bash
HASH_X=$(nix hash convert --hash-algo sha256 --to sri "$RAW_X")
if [[ -z $HASH_X ]]; then
  echo "Error: nix hash convert failed for $RAW_X" >&2
  exit 1
fi
```

Drop the `2>/dev/null` so stderr surfaces, and drop the `|| echo "sha256-$RAW"` so we fail hard instead of writing an invalid SRI.

**Why two statements (avoiding the `local` gotcha):** in bash, `local HASH_X=$(false) || exit 1` does NOT exit — `local` itself is a command, and its exit status (always 0 if `local` succeeded) is what `||` tests. The same trap applies to `declare`, `readonly`, `export`. Today's updaters declare these at top level (not inside functions, so no `local`), but if a future refactor moves them into functions, the one-liner `HASH_X=$(...) || { exit 1; }` form silently degrades. The two-statement form is robust to that.

**Also confirm `set -euo pipefail` is in scope.** Check the top of each updater script — if missing, `nix hash convert` failing produces an empty `HASH_X` without exiting; the `if [[ -z $HASH_X ]]` test is what actually catches it. Add `set -euo pipefail` if it isn't already present (most scripts already have this from `update-locks.sh`).

cmux is single-platform so the script has only one such call. beads-web (after Branch 1) has two calls (down from three). gascity (after Branch 1) has two (down from four).

### Verification

1. `nix flake check --no-build --show-trace` exits 0.
2. From the worktree: `nix run .#fix-lint` runs `statix fix` against the current directory and either applies fixes or no-ops (it's repo-clean already in steady state).
3. From the worktree: `nix run .#fix-lint -- packages/cmux` runs `statix fix` against just that subdir.
4. `update-locks.sh` runs end-to-end on a synthetic version bump (locally — bump beads-web's version to a non-existing tag, observe the updater fail at curl/prefetch rather than at hash-conversion fallback).
5. Negative test for S5: `RAW_X=invalid nix hash convert --hash-algo sha256 --to sri "$RAW_X"` errors; confirm the new wrapper exits 1 instead of writing `sha256-invalid`.

### Risk / Rollback

- B2 is a script change with one behavioral side effect: `fix-lint` no longer modifies the store path, only the working tree. Consumers who relied on the broken behavior get unblocked.
- S5: the failure mode the fallback was masking now surfaces as a hard exit. If the user's nix version is too old to support `nix hash convert`, the updater breaks loudly — which is preferable.
- Rollback: `git revert`.

---

## Cross-Cutting

### Implementer prompt hygiene

Same lessons as Chunk 1 / 2 (apply to all three Chunk 3 implementers):

- **No PRs.** Push the branch; human merges.
- **CI doesn't trigger on feature branches.** Verification is local.
- Work in the worktree; can't `git checkout main` (sibling worktree owns it).
- Vault key infra: `nix fmt --builders '' --max-jobs 4` if remote builder errors on `/run/vault-secrets/nix-signing-key.sec`.

### Beads tracking

None. Per-branch progress is implicit in git log.

### Out-of-scope adjacent items intentionally NOT touched

- The `nix run nixpkgs#nix-prefetch-github` calls in `update-locks.sh` — Chunk 1 Task 4 explicitly kept these unpinned for bootstrap. Don't touch.
- Chunk 2's overlay or granular-deps wiring.
- Branch protection on main.
- `legacyPackages.yaziPlugins` double-eval (Chunk 2 acknowledged this; backlog).
- nvfetcher migration — Chunk 5.

## Success Criteria

After all three branches are merged:

1. No `lib.fakeHash` in any `packages/` file.
2. `meta.platforms` on every package equals the set of platforms with real hashes — no overclaiming.
3. No `/usr/bin/` references in `packages/` or `overlays/`.
4. The firefox overlay's `assert` is in place and would fire if upstream changed the sentinel string. The codesign call uses `pkgs.darwin.sigtool`'s shim, not the host's `/usr/bin/codesign`.
5. `nix run .#fix-lint` operates on `$PWD` (or all positional args via `$@`) at runtime.
6. The 3 updater scripts fail hard on hash-conversion errors (no `|| echo "sha256-$RAW"` fallback).
7. `nix flake check` green; the post-Chunk-1-Task-3 linux-exclusion filter is gone.
8. `grep -RE 'c9watch' .` returns no matches.
9. CI on main is green after each branch's merge.

## Open Questions

None pending. All decisions resolved in dialogue:

- Platform support: match-current-usage-only (aarch64-darwin + x86_64-linux).
- Branch granularity: 3 branches.
- Codesign: `sigtool` (Branch 2).
- DMG unpacker: `undmg` first, fallback to `_7zz` if it errors.
- c9watch: deleted (Branch 1).
- Firefox overlay: kept; codesign → sigtool, plus B10 assertion.

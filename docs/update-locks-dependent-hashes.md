# update-locks: dependent fixed-output hashes

Bead pg2-g39wh. `nvfetcher` moves a package's source (`_sources/`), but some packages carry a hash
that is **derived from** that source: a pnpm dependency store, a Go vendor tree, a cargo lock. When
upstream changes its dependencies, the old hash no longer matches, and the auto-landed bump breaks
the system build (mermaid-live-editor, 2026-10-13: `ERR_PNPM_NO_OFFLINE_TARBALL`). A bumped package
can also stop building outright (cmux 0.65.1, 2026-10-13, pg2-ybbs8).

`refresh-dependent-hashes.sh` closes that gap. `update-locks.sh` runs the `nvfetcher` step **through**
it.

## Policy

- A source bump MUST NOT land with a stale dependent hash. The step MUST recompute it.
- A source bump MUST NOT land when its package no longer builds. The step MUST hold that bump.
- A held bump MUST be reverted for that key only. Other keys' bumps MUST still land.
- A held bump MUST be reported with its reason and MUST be retried by the next run.
- The step MUST NOT override pnpm's `minimumReleaseAge` policy and MUST NOT write a guessed hash.
- A source that is new (no earlier entry to revert to) MUST fail the step when it does not build.
- The provenance gate (`verify-provenance.sh`) MUST run before any build of a bumped source, and it
  is unchanged. The separate `verify-provenance` step still runs every time.

## Flow

```mermaid
flowchart TD
  A["snapshot _sources and dependent hash files"] --> B["run nvfetcher"]
  B --> C{"any key changed?"}
  C -- no --> Z["done"]
  C -- yes --> D["gate: verify-provenance.sh"]
  D -- fails --> F["step fails, framework rolls back"]
  D -- passes --> E["per changed key"]
  E --> G["write placeholder hash, build package"]
  G --> H{"outcome"}
  H -- "hash mismatch, specified is the placeholder" --> I["write got: hash"]
  H -- "ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION" --> J["HOLD: revert key"]
  H -- "any other failure" --> J
  I --> K["build every package registered for the key"]
  K -- builds --> L["keep bump"]
  K -- fails --> J
  J --> M["re-verify the surviving keys"]
  L --> M
  M --> Z
```

The placeholder build is deliberate. With the stale hash, the fixed-output derivation's output path
is already in the store, so nix never refetches and the stale dependency tree is reused; the failure
then appears only in the consuming build. Only a build whose hash is unknown forces a fresh fetch and
gives nix's own `got:` value. The `specified:` value in the mismatch MUST equal the placeholder, so
the `got:` of an unrelated fixed-output derivation (such as the source itself) is never written.

## pnpm minimumReleaseAge

pnpm 11 rejects a dependency published within roughly the last day
(`ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION`). A bump whose new lockfile pulls such a package cannot have
its hash computed yet. The step reports `HELD <key> ... pnpm minimumReleaseAge: ...`, reverts the key,
and tries again on the next run, once the dependency has aged. See pg2-kwuw0.

## Manual use

Recompute (and build-verify) one package's dependent hash without a source bump:

```bash
pg-nix-log-wrapped ./refresh-dependent-hashes.sh --force pint
```

## Inventory

Every overlay package whose build input depends on its source in a way `nvfetcher` does not itself
update. The registry lives at the top of `refresh-dependent-hashes.sh` (`HASH_DEPS`, `MANUAL_DEPS`,
`BUILD_ATTRS`); `tests/refresh-dependent-hashes.bats` fails when this inventory and the code drift:
every `nvfetcher.toml` key MUST be in `BUILD_ATTRS`, and every package directory with a hash literal,
pnpm/npm/yarn fetch, or cargo lock MUST be in `HASH_DEPS` or `MANUAL_DEPS`.

### Refreshed automatically (`HASH_DEPS`)

| nvfetcher key         | File                                       | Literal      | Kind                        |
| --------------------- | ------------------------------------------ | ------------ | --------------------------- |
| `gh-stack`            | `packages/gh-stack/default.nix`            | `vendorHash` | `buildGoModule` vendor tree |
| `glowm`               | `packages/glowm/default.nix`               | `vendorHash` | `buildGoModule` vendor tree |
| `gomu`                | `packages/gomu/default.nix`                | `vendorHash` | `buildGoModule` vendor tree |
| `pint`                | `packages/pint/default.nix`                | `vendorHash` | `buildGoModule` vendor tree |
| `mermaid-ink`         | `packages/mermaid-ink/default.nix`         | `hash`       | `fetchPnpmDeps` (pnpm_11)   |
| `mermaid-live-editor` | `packages/mermaid-live-editor/default.nix` | `hash`       | `fetchPnpmDeps` (pnpm_11)   |

The pnpm version is also part of the pnpm hashes: changing the `pnpm` package or `fetcherVersion` in
these files changes the correct hash. Changing `goVersion` for `pint` likewise changes `vendorHash`. Those
are NOT source bumps, so refresh by hand with `--force <key>`.

### Verified, held on failure, not refreshed (`MANUAL_DEPS`)

| nvfetcher key | File                         | Why it is not refreshed                                                                                                    |
| ------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `mdr-rs`      | `packages/mdr-rs/Cargo.lock` | Hand-copied copy of upstream's lock (`cargoLock.lockFile`), not a hash. A bump that breaks it fails the build and is held. |

### No dependent hash; build-verified only (`BUILD_ATTRS`)

These have no source-derived hash literal. The step still builds them after a bump and holds the bump
when the build fails (the cmux class).

| nvfetcher key                                                               | Built attr (aarch64-darwin only marked \*)                    |
| --------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `cmux`                                                                      | `cmux` \*                                                     |
| `logseq`                                                                    | `logseq` \*                                                   |
| `eclipse-java`                                                              | `eclipse-java` \*, `eclipse-with-gradleimport` \*             |
| `lombok`                                                                    | `eclipse-with-gradleimport` \*                                |
| `bat-gherkin-syntax`, `tmux-*`, `bunny` (`yaziPlugins-bunny`), `icons-brew` | the package of the same name (plain `fetchFromGitHub` source) |

On a system that does not expose an attr (the `*` ones on Linux) the step logs `skipping build of ...`
and the bump is not verified there.

### Not covered

- Any `hash` that depends on something other than the nvfetcher source (a toolchain change). Use
  `--force`.
- Dependencies pulled from nixpkgs (no hash in this repo).

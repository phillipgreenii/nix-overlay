# phillipgreenii-nix-overlay

Third-party Nix packages absent from or outdated in nixpkgs.

## Usage

Add to your flake's `inputs`:

```nix
inputs.phillipgreenii-nix-overlay = {
  url = "github:phillipgreenii/nix-overlay";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Apply the overlay to a `pkgs` import (NixOS, home-manager, or any flake consuming nixpkgs):

```nix
pkgs = import nixpkgs {
  system = "x86_64-linux";
  overlays = [ phillipgreenii-nix-overlay.overlays.default ];
};
```

After that, `pkgs.phillipgreenii.bat-gherkin-syntax`, `pkgs.phillipgreenii.pint`, `pkgs.tmuxPlugins.tmux-open-nvim`, etc. resolve normally.

## Packages

| Name                                         | Platforms      | Source                                                                                                 |
| -------------------------------------------- | -------------- | ------------------------------------------------------------------------------------------------------ |
| `phillipgreenii.bat-gherkin-syntax`          | unix           | [keith-hall/SublimeGherkinSyntax](https://github.com/keith-hall/SublimeGherkinSyntax)                  |
| `phillipgreenii.cmux`                        | aarch64-darwin | [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)                                                |
| `phillipgreenii.eclipse-java`                | aarch64-darwin | [Eclipse EPP 2026-06-R .dmg](https://download.eclipse.org/technology/epp/downloads/release/2026-06/R/) |
| `phillipgreenii.eclipse-gradleimport-plugin` | aarch64-darwin | (in this repo, `packages/eclipse-gradleimport-plugin`)                                                 |
| `phillipgreenii.eclipse-with-gradleimport`   | aarch64-darwin | (composed: `eclipse-java` + `eclipse-gradleimport-plugin`)                                             |
| `phillipgreenii.gh-stack`                    | unix           | [github/gh-stack](https://github.com/github/gh-stack) (also flat: `pkgs.gh-stack`)                     |
| `phillipgreenii.glowm`                       | unix           | [atani/glowm](https://github.com/atani/glowm)                                                          |
| `phillipgreenii.gomu`                        | unix           | [sivchari/gomu](https://github.com/sivchari/gomu)                                                      |
| `phillipgreenii.logseq`                      | aarch64-darwin | [logseq/logseq](https://github.com/logseq/logseq) (arm64 `.dmg`)                                       |
| `phillipgreenii.mdr-rs`                      | unix           | [CleverCloud/mdr](https://github.com/CleverCloud/mdr)                                                  |
| `phillipgreenii.mermaid-ink`                 | unix           | [jihchi/mermaid.ink](https://github.com/jihchi/mermaid.ink)                                            |
| `phillipgreenii.mermaid-live-editor`         | unix           | [mermaid-js/mermaid-live-editor](https://github.com/mermaid-js/mermaid-live-editor)                    |
| `phillipgreenii.pint`                        | unix           | [cloudflare/pint](https://github.com/cloudflare/pint)                                                  |
| `tmuxPlugins.tmux-open-nvim`                 | unix           | [trevarj/tmux-open-nvim](https://github.com/trevarj/tmux-open-nvim)                                    |
| `tmuxPlugins.tmux-mouse-swipe`               | unix           | [jaclu/tmux-mouse-swipe](https://github.com/jaclu/tmux-mouse-swipe)                                    |
| `tmuxPlugins.tmux-nerd-font-window-name`     | unix           | [joshmedeski/tmux-nerd-font-window-name](https://github.com/joshmedeski/tmux-nerd-font-window-name)    |
| `yaziPlugins.icons-brew`                     | all            | [lpnh/icons-brew.yazi](https://github.com/lpnh/icons-brew.yazi) (packaged in `packages/yaziPlugins`)   |
| `yaziPlugins.bunny`                          | all            | [stelcodes/bunny.yazi](https://github.com/stelcodes/bunny.yazi) (packaged in `packages/yaziPlugins`)   |

`legacyPackages.${system}.yaziPlugins` exposes the structured `{ icons-brew, bunny }` set; under `packages.${system}` the same plugins are the flat attributes `yaziPlugins-icons-brew` and `yaziPlugins-bunny`.

## Other outputs

- `overlays.firefox-binary-wrapper` — opt-in: replaces nixpkgs' Firefox `makeWrapper` with `makeBinaryWrapper` so macOS attributes TCC permissions to `firefox` (not `bash`).
- `pkgs.firefoxAddons` — re-export of the hash-pinned Firefox add-ons from NUR's `rycee` `firefox-addons` set, instantiated against the consumer's `pkgs` (provided by `overlays.default`; NUR is only evaluated when an add-on is forced), so a home-manager Firefox profile can pin extensions.
- `pkgs.buildGoModuleFor` — `buildGoModuleFor <goVersion>` resolves to the `buildGoNNNModule` matching a package's own `go.mod` minimum (plain `buildGoModule` for `null`); provided by `overlays.default` (see `lib/versioned-go-module.nix`).
- `homeModules.install-metadata` — emits a marker file describing the overlay revision into the user's profile (consumed by personal home-manager configs).

## Update automation

`update-locks.sh` (run by `.github/workflows/update-flakes.yml` nightly) bumps package sources via `nvfetcher` (through `refresh-dependent-hashes.sh`, which recomputes the dependent `vendorHash`/pnpm `hash` literals, builds each bumped package, and holds back any bump that cannot be refreshed or no longer builds; see [`docs/update-locks-dependent-hashes.md`](docs/update-locks-dependent-hashes.md)), runs the provenance hook (`verify-provenance.sh`; see below), then bumps `flake.lock`. The workflow opens a PR and enables auto-merge (rebase). `main` is intentionally not a protected branch and has no required status checks, so the merge is **not** gated on CI — `ci.yml` runs for visibility only, and direct pushes to `main` are allowed.

### Integrity and provenance

Integrity today rests on two mechanisms:

1. **Content-hash pinning.** `nvfetcher` pins every source — git revision or release artifact — to a SHA-256 SRI hash under `_sources/`. Nix refuses to build if the fetched bytes don't match the pin, so a silent upstream swap fails the build rather than shipping.
2. **Update-time VERIFY build.** On every update run, `refresh-dependent-hashes.sh` builds each package whose source changed (the `BUILD_ATTRS` registry) with the refreshed dependent hashes, and HOLDS any bump that does not build: that key's source entry is reverted and retried on the next run, so a non-building bump is not landed by the updater. This build, not CI, decides whether a bump lands.

`ci.yml` additionally runs `nix flake check --all-systems` (which builds every package as a check on the runner's own system) on every push to and pull request against `main`. It is for visibility only: `main` has no branch protection and no required checks, so CI is **not** a merge gate.

`verify-provenance.sh` (run in `update-locks.sh` as the per-key `--gate` of `refresh-dependent-hashes.sh`, as `verify-provenance.sh <key>` for each changed key after `nvfetcher` and before any build, and again with no arguments as its own idempotent step before `nix flake update`) is an _additional_, per-upstream provenance hook layered on top. A key that fails the gate is held alone: its bump is reverted, a `PROVENANCE-HELD <key>: <reason>` line is printed, the other keys' bumps still land, and the run is flagged failed (a later `provenance-held` step; it changes nothing, so the passing keys' commits stay). A brand-new key (no earlier entry to restore) cannot be held and fails the step. Each upstream has a method in the `METHODS` table at the top of the script:

- `checksums` — the download is compared against the release-dir hash manifest the upstream publishes. A fetch failure or a mismatch holds that key's bump (`PROVENANCE-HELD`) and flags the run failed.
- `none-no-provenance-published` — the upstream publishes no usable attestation, checksum manifest, or signature. The helper logs the gap and continues; the nvfetcher SRI pin remains the integrity proof.
- `git-source` — explicitly skipped: the nvfetcher-pinned commit SHA is the integrity proof.

The script also carries `attestation` and `sigstore` verifiers, which no upstream uses today (they run only when an upstream's `METHODS` entry is switched to one of them); both re-check the download against the pinned SRI before trusting it.

Per-upstream method assignment (the `METHODS` table; audit dates are those recorded in the script header, where the umbrella audit of the table is 2026-06-18):

| Upstream (METHODS key)                  | Method                         | Audit      | Notes                                                                                                                                                                                                              |
| --------------------------------------- | ------------------------------ | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `cmux` (`manaflow-ai/cmux`)             | `none-no-provenance-published` | 2026-06-18 | `cmux-macos.dmg` has no attestation and no `.dmg.sig`. The `cmuxd-remote-checksums.txt` published alongside covers a _different_ product (cmuxd-remote), not the cmux app.                                         |
| `eclipse-java` (`download.eclipse.org`) | `none-no-provenance-published` | 2026-07-21 | The Eclipse EPP `.dmg` is served from `download.eclipse.org` (not GitHub, so no `gh attestation`); no `.dmg.sig` / cosign signature is published next to the artifact.                                             |
| `lombok` (Maven Central)                | `none-no-provenance-published` | 2026-07-22 | Maven Central publishes a detached PGP `.asc` and per-file `.sha1`/`.md5`, but none of the mechanized methods fit (no `checksums.txt`, GPG rather than cosign), so the gap is logged and the SRI pin is the proof. |
| `logseq` (`logseq/logseq`)              | `checksums`                    | 2026-07-28 | No GitHub attestation and no cosign signature, but the release publishes a `SHA256SUMS.txt` manifest, which the script checks against the pinned hash. Not a provenance gap.                                       |
| `tmux-open-nvim`                        | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `tmux-mouse-swipe`                      | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `tmux-nerd-font-window-name`            | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `bat-gherkin-syntax`                    | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `pint`                                  | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `glowm`                                 | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `gomu`                                  | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `mdr-rs`                                | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `mermaid-ink`                           | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `mermaid-live-editor`                   | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `gh-stack`                              | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `bunny`                                 | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |
| `icons-brew`                            | `git-source`                   | 2026-06-18 | Skipped by design: the nvfetcher-pinned commit SHA is the integrity proof.                                                                                                                                         |

`pint`, `glowm`, `gomu` and `gh-stack` are `fetchFromGitHub` sources repackaged with `buildGoModule`; there is no release binary to attest. `mermaid-live-editor` tracks the upstream `develop` branch head, since upstream publishes no tags.

When an upstream's release pipeline changes (publishes/withdraws attestation or checksums), its `METHODS` entry at the top of `verify-provenance.sh` MUST be re-audited. Search for the key's "audit <date>" line in that file's header to find its config block.

## ADRs

See [`docs/adr/`](docs/adr/) for the rationale behind this repo's existence and structure:

- [0000 — Use Architecture Decision Records](docs/adr/0000-use-architecture-decision-records.md)
- [0001 — Purpose of this repo](docs/adr/0001-purpose-of-this-repo.md)
- [0002 — firefox-binary-wrapper: sign the Firefox.app bundle with rcodesign](docs/adr/0002-firefox-binary-wrapper-rcodesign-signing.md)

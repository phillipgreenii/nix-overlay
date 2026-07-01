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

After that, `pkgs.phillipgreenii.bat-gherkin-syntax`, `pkgs.tmuxPlugins.tmux-open-nvim`, etc. resolve normally.

## Packages

| Name                                     | Platforms      | Source                                                                                              |
| ---------------------------------------- | -------------- | --------------------------------------------------------------------------------------------------- |
| `phillipgreenii.bat-gherkin-syntax`      | unix           | [keith-hall/SublimeGherkinSyntax](https://github.com/keith-hall/SublimeGherkinSyntax)               |
| `phillipgreenii.cmux`                    | aarch64-darwin | [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)                                             |
| `tmuxPlugins.tmux-open-nvim`             | unix           | [trevarj/tmux-open-nvim](https://github.com/trevarj/tmux-open-nvim)                                 |
| `tmuxPlugins.tmux-mouse-swipe`           | unix           | [jaclu/tmux-mouse-swipe](https://github.com/jaclu/tmux-mouse-swipe)                                 |
| `tmuxPlugins.tmux-nerd-font-window-name` | unix           | [joshmedeski/tmux-nerd-font-window-name](https://github.com/joshmedeski/tmux-nerd-font-window-name) |
| `yaziPlugins.icons-brew`                 | all            | (in this repo, `packages/yaziPlugins/icons-brew`)                                                   |
| `yaziPlugins.bunny`                      | all            | (in this repo, `packages/yaziPlugins/bunny`)                                                        |

`legacyPackages.${system}.yaziPlugins` exposes the structured `{ icons-brew, bunny }` set.

## Other outputs

- `overlays.firefox-binary-wrapper` — opt-in: replaces nixpkgs' Firefox `makeWrapper` with `makeBinaryWrapper` so macOS attributes TCC permissions to `firefox` (not `bash`).
- `homeModules.install-metadata` — emits a marker file describing the overlay revision into the user's profile (consumed by personal home-manager configs).

## Update automation

`update-locks.sh` (run by `.github/workflows/update-flakes.yml` nightly) bumps package sources via `nvfetcher`, verifies provenance, then bumps `flake.lock`. The workflow opens a PR which auto-merges after CI passes on the gated `main` branch.

### Provenance verification

The nightly updater (`verify-provenance.sh`, invoked between `nvfetcher` and `nix flake update` in `update-locks.sh`) verifies every binary upstream's release artifact against published provenance. Per-upstream method assignment (audit **2026-06-18**):

| Upstream           | Method                         | Notes                                                                                                                                                                                                                  |
| ------------------ | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `manaflow-ai/cmux` | `none-no-provenance-published` | `cmux-macos.dmg` has no attestation and no `.dmg.sig`. The `cmuxd-remote-checksums.txt` published alongside covers a _different_ product (cmuxd-remote), not the cmux Electron app. Helper logs the gap and continues. |

Git-source plugins (`tmux-*`, `bat-gherkin-syntax`) are not verified separately — the nvfetcher-pinned commit SHA is the integrity proof.

When an upstream's release pipeline changes (publishes/withdraws attestation or checksums), the per-upstream `METHODS` table at the top of `verify-provenance.sh` must be re-audited. Search for "audit 2026-06-18" in that file to find the config block.

## ADRs

See [`docs/adr/`](docs/adr/) for the rationale behind this repo's existence and structure:

- [0000 — Use Architecture Decision Records](docs/adr/0000-use-architecture-decision-records.md)
- [0001 — Purpose of this repo](docs/adr/0001-purpose-of-this-repo.md)

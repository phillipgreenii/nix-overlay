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

After that, `pkgs.beads-web`, `pkgs.tmuxPlugins.tmux-open-nvim`, etc. resolve normally.

## Packages

| Name | Platforms | Source |
| --- | --- | --- |
| `beads-web` | aarch64-darwin, x86_64-linux | [weselow/beads-web](https://github.com/weselow/beads-web) |
| `gascity` | aarch64-darwin, x86_64-linux | [gastownhall/gascity](https://github.com/gastownhall/gascity) |
| `bat-gherkin-syntax` | unix | [keith-hall/SublimeGherkinSyntax](https://github.com/keith-hall/SublimeGherkinSyntax) |
| `tmuxPlugins.tmux-open-nvim` | unix | [trevarj/tmux-open-nvim](https://github.com/trevarj/tmux-open-nvim) |
| `tmuxPlugins.tmux-mouse-swipe` | unix | [jaclu/tmux-mouse-swipe](https://github.com/jaclu/tmux-mouse-swipe) |
| `tmuxPlugins.tmux-nerd-font-window-name` | unix | [joshmedeski/tmux-nerd-font-window-name](https://github.com/joshmedeski/tmux-nerd-font-window-name) |
| `yaziPlugins.icons-brew` | all | (in this repo, `packages/yaziPlugins/icons-brew`) |
| `yaziPlugins.bunny` | all | (in this repo, `packages/yaziPlugins/bunny`) |
| `cmux` | darwin (aarch64-darwin verified) | [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) |

`legacyPackages.${system}.yaziPlugins` exposes the structured `{ icons-brew, bunny }` set.

## Other outputs

- `overlays.firefox-binary-wrapper` — opt-in: replaces nixpkgs' Firefox `makeWrapper` with `makeBinaryWrapper` so macOS attributes TCC permissions to `firefox` (not `bash`).
- `homeModules.install-metadata` — emits a marker file describing the overlay revision into the user's profile (consumed by personal home-manager configs).
- `apps.update-{cmux,beads-web,gascity}` — internal updater apps invoked by `update-locks.sh`.

## Update automation

`update-locks.sh` (run by `.github/workflows/update-flakes.yml` nightly) bumps package versions and hashes; the workflow opens a PR which auto-merges after CI passes on the gated `main` branch.

## ADRs

See [`docs/adr/`](docs/adr/) for the rationale behind this repo's existence and structure:

- [0000 — Use Architecture Decision Records](docs/adr/0000-use-architecture-decision-records.md)
- [0001 — Purpose of this repo](docs/adr/0001-purpose-of-this-repo.md)

# Purpose: Third-Party Package Repository

**Status**: Accepted
**Date**: 2026-04-28
**Deciders**: Phillip Green II

## Context

Personal and work Nix configurations required custom derivations for tools that either:

- (a) have no existing Nix flake upstream, or
- (b) exist in nixpkgs but at a version too outdated to be useful

These derivations were scattered across `phillipgreenii-nix-personal` (cmux,
c9watch, tmux plugins, bat syntax) and `phillipg-nix-ziprecruiter` (beads-web).
Each repo ran its own update scripts to keep hashes current, and changes to
these packages caused noise in the downstream repos' commit history.

## Decision

Consolidate all custom third-party package derivations into a dedicated public
repository `phillipgreenii/nix-overlay`.

- Each package lives in `packages/<name>/` with its own derivation file
- The repo exposes `packages.${system}.*` and `overlays.default`
- The repo owns all per-package hash update logic in `update-locks.sh`
- A nightly GitHub Actions workflow (daily at `0 11 * * *`, 6 AM EST) keeps all packages current
- Downstream repos (personal, ZR) consume via flake input and `overlays.default`
- Downstream `update-locks.sh` scripts simplify to `nix flake update` only

## Consequences

### Positive

- Update cadence (nightly) is decoupled from downstream repos (their own schedules)
- Package history is isolated to this repo; downstream commit logs are cleaner
- Clear single location to add new third-party packages
- Single `nix flake update` in downstream repos picks up all package updates

### Negative

- One more repo in the workspace `flakeProjects` list; one more step in the update sequence
- Package changes require two PRs: one in this repo, one in each consuming repo

### Neutral

- Downstream repos gain a new flake input dependency (`phillipgreenii-nix-overlay`)

## Alternatives Considered

### Keep packages in each consuming repo

**Rejected**: Duplicates update logic, pollutes downstream commit history with
third-party version bumps, and makes it harder to add a new package that
multiple repos need.

### Use NUR (Nix User Repository)

**Rejected**: Requires NUR registration and a specific repo structure. The
overlay pattern is simpler and already established in the workspace.

## Related Decisions

See also: phillipg-nix-ziprecruiter docs/adr/0013-update-sequence-np-then-sa-then-zr-via-flakeprojects-order.md
See also: phillipgreenii-nix-personal docs/adr/0000-use-architecture-decision-records.md

#!/usr/bin/env bash
# Standalone developer utility — not Nix-wrapped intentionally
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${SCRIPT_DIR}/.."

case "${1:-}" in
--ci)
  export UL_CI_MODE=true
  shift
  ;;
-h | --help)
  echo "Usage: $0 [--ci]"
  echo "  --ci  Disable laptop-only checks (nix daemon health, time-based cache)"
  exit 0
  ;;
"") ;;
*)
  echo "Unknown argument: $1" >&2
  echo "Usage: $0 [--ci]" >&2
  exit 1
  ;;
esac

# Guard: distinguish missing flake.lock (legitimate bootstrap) from corrupt
# flake.lock (operator must restore). The self-repair path below tolerates an
# unresolvable `phillipgreenii-nix-base.locked.rev` by falling back to unpinned
# HEAD; corruption should not be absorbed by that fallback. tc-0ixb2.
if [ -e flake.lock ]; then
  if ! jq -e '.nodes.root' flake.lock >/dev/null 2>&1; then
    echo "update-locks.sh: flake.lock is present but corrupt (not valid JSON or missing .nodes.root)." >&2
    echo "  Restore from git: git checkout HEAD -- flake.lock" >&2
    exit 1
  fi
else
  echo "update-locks.sh: flake.lock is missing; nix flake update will bootstrap it." >&2
fi

# Resolve which update-locks-lib.bash to source via the canonical flake resolver.
# Pin nix-repo-base to the locked rev via the shared resolve-nrb-ref helper
# (pg2-pwfqqn ruling a+c). FAIL CLOSED: there is no unpinned fallback. The helper
# cannot be run without a rev, so the bootstrap reads the rev straight from
# flake.lock and aborts when the node is missing (run `nix flake lock`).
NRB_BOOT_REV=$(jq -er '.nodes."phillipgreenii-nix-base".locked.rev' "${SCRIPT_DIR}/flake.lock") ||
  {
    echo "update-locks.sh: flake.lock has no phillipgreenii-nix-base rev; run 'nix flake lock'" >&2
    exit 1
  }
NRB_REF=$(nix run "github:phillipgreenii/nix-repo-base/${NRB_BOOT_REV}#resolve-nrb-ref" -- --lock "${SCRIPT_DIR}/flake.lock") || exit 1

# Pass WORKSPACE_ROOT so the resolver can prefer the on-disk sibling when present.
export WORKSPACE_ROOT
UL_LIB_DIR="${UL_LIB_DIR:-$(nix run "${NRB_REF}#determine-ul-lib-dir")}"
# shellcheck disable=SC1091
source "${UL_LIB_DIR}/update-locks-lib.bash"
ul_reexec_in_dev_shell "$@"
ul_setup "phillipgreenii-nix-overlay" "${SCRIPT_DIR}"

# Prefer the devShell-pinned nvfetcher when it is on PATH: `ul_reexec_in_dev_shell`
# above re-execs into this flake's devShell (extraInputs ships nvfetcher), so a
# normal CI/laptop run uses the pinned binary instead of fetching+running
# registry-HEAD `nixpkgs#nvfetcher` (unpinned code, executed fresh each run —
# pg2-y4brd). Fall back to `nix run nixpkgs#nvfetcher` ONLY when nvfetcher is
# absent, which keeps the updater bootstrappable when this flake's devShell or
# flake.lock is itself the artifact being repaired. See nix-repo-base's
# 2026-05-29 update-locks-resilience design (lines 35, 262).
if command -v nvfetcher >/dev/null 2>&1; then
  nvfetcher_cmd=(nvfetcher)
else
  echo "update-locks.sh: nvfetcher not on PATH (devShell unavailable?); falling back to unpinned nix run nixpkgs#nvfetcher" >&2
  nvfetcher_cmd=(nix run nixpkgs#nvfetcher --)
fi
# The step runs nvfetcher THROUGH refresh-dependent-hashes.sh (pg2-g39wh): for each
# source that moved it runs the provenance gate (verify-provenance.sh KEY), recomputes
# the dependent fixed-output hashes (pnpmDeps, vendorHash), builds the package, and
# HOLDS (reverts) ONLY the keys that fail provenance, cannot be refreshed or no longer
# build -- including a pnpm minimumReleaseAge refusal -- instead of landing a broken
# lock; the other keys land (pg2-yfre4n). The framework rolls back every change of a
# step that exits non-zero, so the step exits 0 and records its PROVENANCE-HELD lines
# in a report file; the "provenance-held" step below then fails (changing nothing) so
# the run is visibly flagged while the passing keys' commits stay. The separate
# verify-provenance step stays as the idempotent every-run check: a held key's entry
# is already restored to the previously landed one, so it does not re-fail there.
rdh_held_report="$(mktemp)"
ul_run_step "nvfetcher" \
  "update-locks: update sources via nvfetcher" \
  "$SCRIPT_DIR/refresh-dependent-hashes.sh" --gate "$SCRIPT_DIR/verify-provenance.sh" \
  --held-report "$rdh_held_report" -- \
  "${nvfetcher_cmd[@]}" --build-dir _sources --config nvfetcher.toml

ul_run_step "verify-provenance" \
  "update-locks: verify provenance of nvfetcher source updates" \
  "$SCRIPT_DIR/verify-provenance.sh"

# Flag the run when any key was held for provenance. Changes nothing, so its
# non-zero exit rolls back nothing; it only marks the run failed.
ul_run_step "provenance-held" \
  "update-locks: report provenance-held keys" \
  bash -c 'if [ -s "$1" ]; then cat "$1" >&2; exit 1; fi' _ "$rdh_held_report"

ul_run_step "nix-flake-update" \
  "update-locks: update nix flake.lock" \
  nix flake update

# Refresh the SHA pins of every `uses: owner/repo@<sha> # <ref>` in .github/workflows
# (ul_refresh_action_pins, shared step from nix-repo-base lib/scripts/update-action-pins-lib.bash;
# beads pg2-ehu9q, pg2-z82la). Mutable refs are reported, not rewritten.
ul_run_step "github-action-pins" \
  "update-locks: refresh GitHub Action SHA pins" \
  ul_refresh_action_pins

ul_finalize

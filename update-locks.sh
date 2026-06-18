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
# Pin nix-repo-base to the locked rev (closes the unpinned-HEAD code-execution
# hole that GH_TOKEN-bearing CI would otherwise expose). Fall back to unpinned
# HEAD when the lock itself is the broken artifact, preserving the self-repair
# property — see Step 4.5 and nix-repo-base's 2026-05-29 update-locks-resilience
# design doc (lines 35, 262).
NRB_REV=$(nix flake metadata --json 2>/dev/null |
  jq -r '.locks.nodes."phillipgreenii-nix-base".locked.rev // empty')
if [ -n "$NRB_REV" ]; then
  NRB_REF="github:phillipgreenii/nix-repo-base/${NRB_REV}"
else
  echo "WARN: could not resolve nix-repo-base from flake.lock; using unpinned HEAD" >&2
  NRB_REF="github:phillipgreenii/nix-repo-base"
fi

# Pass WORKSPACE_ROOT so the resolver can prefer the on-disk sibling when present.
export WORKSPACE_ROOT
UL_LIB_DIR="${UL_LIB_DIR:-$(nix run "${NRB_REF}#determine-ul-lib-dir")}"
# shellcheck disable=SC1091
source "${UL_LIB_DIR}/update-locks-lib.bash"
ul_reexec_in_dev_shell "$@"
ul_setup "phillipgreenii-nix-overlay" "${SCRIPT_DIR}"

# Use `nix run nixpkgs#nvfetcher` (unpinned) deliberately: the updater
# must remain bootstrappable when this flake's devShell or flake.lock
# is itself the artifact being repaired. See nix-repo-base's 2026-05-29
# update-locks-resilience design (lines 35, 262).
ul_run_step "nvfetcher" \
  "update-locks: update sources via nvfetcher" \
  nix run nixpkgs#nvfetcher -- --build-dir _sources --config nvfetcher.toml

ul_run_step "verify-provenance" \
  "update-locks: verify provenance of nvfetcher source updates" \
  "$SCRIPT_DIR/verify-provenance.sh"

ul_run_step "nix-flake-update" \
  "update-locks: update nix flake.lock" \
  nix flake update

ul_finalize

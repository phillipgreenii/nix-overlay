#!/usr/bin/env bash
# Provenance verification for binary upstreams (S3/M6).
# Runs after the nvfetcher step in update-locks.sh; verifies every
# configured upstream against its per-upstream method assigned at audit
# time. Verification is idempotent — runs each invocation, not just on
# source change.
#
# Per-upstream methods (audit 2026-06-18 — re-audit if upstream changes
# release pipeline):
#   cmux      — none-no-provenance-published (manaflow-ai/cmux ships
#               cmux-macos.dmg + appcast.xml; no attestation, no
#               .dmg.sig, and the cmuxd-remote-checksums.txt covers a
#               different product, not cmux-macos.dmg)
#
# Git-source packages (tmux-*, bat-gherkin-syntax, pint) use method
# `git-source` — explicitly skipped because the nvfetcher-pinned SHA is the
# integrity. (pint is a rev-pinned fetchFromGitHub source repackaged with
# buildGoModule; the source pin, not a release binary, is what is verified.)
#
# When method is `none-no-provenance-published`, the helper logs the gap
# and continues (does NOT fail). Per Chunk 6 brainstorm decision
# 2026-06-18: both binary upstreams currently publish no provenance;
# rather than block all binary updates (hard-fail), document the gap
# and re-audit when upstream changes their release pipeline.
#
# When ANY upstream method fails (attestation/checksums/sigstore
# verification mismatch, or an `unknown method` entry), the helper
# rolls back the prior commit via `git reset --hard HEAD~1` so the
# workflow's PR step does not fire.
set -euo pipefail

# Refuse to run on a dirty tree — rollback uses `git reset --hard HEAD~1`
# which would silently destroy uncommitted edits if any existed.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "verify-provenance: refusing to run on a dirty working tree (uncommitted changes present)" >&2
  echo "  commit or stash before retrying." >&2
  exit 1
fi

# --- per-upstream method config (audit-time decision; 2026-06-18) ---
declare -A METHODS=(
  ["cmux"]="none-no-provenance-published"
  ["tmux-open-nvim"]="git-source"
  ["tmux-mouse-swipe"]="git-source"
  ["tmux-nerd-font-window-name"]="git-source"
  ["bat-gherkin-syntax"]="git-source"
  ["pint"]="git-source"
)
declare -A REPOS=(
  ["cmux"]="manaflow-ai/cmux"
)

# Extract `url = "..."` from a key's source block (fetchurl-style only).
extract_url() {
  local key="$1"
  awk -v key="$key" '
    $0 ~ ("^  " key " = \\{") { in_block = 1; next }
    in_block && /url = / {
      gsub(/.*url = "/, ""); gsub(/".*/, "")
      print; exit
    }' _sources/generated.nix
}

# Extract `sha256 = "sha256-BASE64"` from a key's source block (SRI form).
extract_sri() {
  local key="$1"
  awk -v key="$key" '
    $0 ~ ("^  " key " = \\{") { in_block = 1; next }
    in_block && /sha256 = / {
      gsub(/.*sha256 = "/, ""); gsub(/".*/, "")
      print; exit
    }' _sources/generated.nix
}

verify_attestation() {
  local key="$1" url
  url=$(extract_url "$key")
  if [ -z "$url" ]; then
    echo "verify-provenance: $key: could not extract URL from _sources/generated.nix" >&2
    return 1
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064  # expand-now is intentional: $tmpdir is set just above.
  trap "rm -rf '$tmpdir'" RETURN
  if ! curl --location --silent --show-error --fail --output "$tmpdir/artifact" "$url"; then
    echo "verify-provenance: $key: download failed ($url)" >&2
    return 1
  fi
  if ! gh attestation verify "$tmpdir/artifact" --repo "${REPOS[$key]}" 2>&1; then
    echo "verify-provenance: $key: gh attestation verify failed" >&2
    return 1
  fi
}

verify_checksums() {
  local key="$1" url
  url=$(extract_url "$key")
  if [ -z "$url" ]; then
    echo "verify-provenance: $key: could not extract URL from _sources/generated.nix" >&2
    return 1
  fi
  local recorded_sri
  recorded_sri=$(extract_sri "$key")
  if [ -z "$recorded_sri" ]; then
    echo "verify-provenance: $key: could not extract recorded SRI hash" >&2
    return 1
  fi
  local artifact_name release_base
  artifact_name=$(basename "$url")
  release_base="${url%/"$artifact_name"}"
  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064  # expand-now is intentional: $tmpdir is set just above.
  trap "rm -rf '$tmpdir'" RETURN
  if ! curl --location --silent --show-error --fail --output "$tmpdir/checksums.txt" "$release_base/checksums.txt"; then
    echo "verify-provenance: $key: failed to download checksums.txt from $release_base" >&2
    return 1
  fi
  local upstream_hex
  upstream_hex=$(awk -v name="$artifact_name" '
    { for (i = 1; i <= NF; i++) if ($i == name || $i == "*"name) { print $1; exit } }
  ' "$tmpdir/checksums.txt")
  if [ -z "$upstream_hex" ]; then
    echo "verify-provenance: $key: artifact '$artifact_name' not listed in checksums.txt" >&2
    return 1
  fi
  # Portable base64 (Linux `base64 -w0` ≠ macOS `base64`): pipe to `tr -d '\n'`.
  local upstream_sri
  upstream_sri="sha256-$(printf '%s' "$upstream_hex" | xxd -r -p | base64 | tr -d '\n')"
  if [ "$upstream_sri" != "$recorded_sri" ]; then
    echo "verify-provenance: $key: hash mismatch — nvfetcher recorded '$recorded_sri', upstream checksums.txt says '$upstream_sri' (hex: $upstream_hex)" >&2
    return 1
  fi
}

verify_sigstore() {
  local key="$1" url
  url=$(extract_url "$key")
  if [ -z "$url" ]; then
    echo "verify-provenance: $key: could not extract URL from _sources/generated.nix" >&2
    return 1
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064  # expand-now is intentional: $tmpdir is set just above.
  trap "rm -rf '$tmpdir'" RETURN
  if ! curl --location --silent --show-error --fail --output "$tmpdir/artifact" "$url"; then
    echo "verify-provenance: $key: download failed ($url)" >&2
    return 1
  fi
  if ! curl --location --silent --show-error --fail --output "$tmpdir/artifact.sig" "$url.sig"; then
    echo "verify-provenance: $key: signature download failed ($url.sig)" >&2
    return 1
  fi
  if ! cosign verify-blob --signature "$tmpdir/artifact.sig" "$tmpdir/artifact" 2>&1; then
    echo "verify-provenance: $key: cosign verify-blob failed" >&2
    return 1
  fi
}

# --- main loop: verify every configured key every run ---
fail=0
for key in "${!METHODS[@]}"; do
  method="${METHODS[$key]}"
  case "$method" in
  attestation) verify_attestation "$key" || fail=1 ;;
  checksums) verify_checksums "$key" || fail=1 ;;
  sigstore) verify_sigstore "$key" || fail=1 ;;
  git-source)
    # Intentional no-op: git-fetched sources have no separate provenance
    # artifact; the nvfetcher-pinned commit SHA is the integrity proof.
    echo "verify-provenance: $key: skipped (git source, SHA pin is integrity)"
    ;;
  none-no-provenance-published)
    # Intentional no-op with explicit gap log. Audit 2026-06-18: this
    # upstream publishes neither GitHub attestations, checksums.txt, nor
    # cosign signatures. Re-audit if upstream changes their release
    # pipeline (see this file's header comment for context).
    echo "verify-provenance: $key: skipped (no upstream provenance as of 2026-06-18 audit)"
    ;;
  *)
    echo "verify-provenance: $key: unknown method '$method'" >&2
    fail=1
    ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  echo "verify-provenance: at least one upstream failed provenance check" >&2
  if git rev-parse HEAD~1 >/dev/null 2>&1; then
    echo "verify-provenance: rolling back to HEAD~1" >&2
    git reset --hard HEAD~1
  fi
  exit 1
fi

echo "verify-provenance: all configured upstreams verified."

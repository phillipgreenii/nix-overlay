#!/usr/bin/env bash
# Provenance verification for binary upstreams (S3/M6).
# Runs after the nvfetcher step in update-locks.sh; verifies every
# configured upstream against its per-upstream method assigned at audit
# time. Verification is idempotent — runs each invocation, not just on
# source change.
#
# Per-upstream methods (audit 2026-06-18 — re-audit if upstream changes
# release pipeline):
#   cmux         — none-no-provenance-published (manaflow-ai/cmux ships
#                  cmux-macos.dmg + appcast.xml; no attestation, no
#                  .dmg.sig, and the cmuxd-remote-checksums.txt covers a
#                  different product, not cmux-macos.dmg)
#   eclipse-java — none-no-provenance-published (audit 2026-07-21). The Eclipse
#                  EPP .dmg is served from download.eclipse.org, not GitHub, so
#                  `gh attestation` does not apply, and no .dmg.sig / cosign
#                  signature is published beside the artifact. No REPOS entry:
#                  none-no-provenance-published never consults REPOS (only
#                  verify_attestation does, via `--repo owner/repo`), and this
#                  upstream has no GitHub owner/repo slug.
#   lombok       — none-no-provenance-published (audit 2026-07-22). The lombok
#                  jar is fetched from Maven Central. Maven Central does publish
#                  a detached PGP signature (lombok-$ver.jar.asc) and per-file
#                  .sha1/.md5 sidecars — but NONE of the mechanized methods here
#                  fit: `attestation` is GitHub-only; `checksums` expects a
#                  single release-dir `checksums.txt` (Maven has per-artifact
#                  .sha1, not that file); `sigstore` uses a cosign `.sig` (Maven
#                  uses GPG `.asc`, which would need lombok's trusted signing
#                  key — no such verifier exists here). So this is treated as the
#                  same "log the gap, do not fail" bucket as the other fetchurl
#                  upstreams; the nvfetcher-pinned SRI remains the content
#                  integrity guarantee. Re-audit (and consider adding a
#                  Maven .asc/.sha1 verifier) if this needs hardening. No REPOS
#                  entry (not a GitHub owner/repo slug).
#   logseq       — checksums (audit 2026-07-28). logseq/logseq publishes NO
#                  GitHub attestations (the attestations API 404s for the .dmg
#                  digest) and no cosign `.dmg.sig`, but it DOES publish a
#                  release-dir hash manifest — so this is genuinely verifiable
#                  and is NOT a none-no-provenance-published gap. The manifest
#                  is named `SHA256SUMS.txt`, not `checksums.txt`, which is why
#                  CHECKSUM_FILES below exists. No REPOS entry (only
#                  verify_attestation consults it).
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
# verification mismatch, or an `unknown method` entry), the helper exits
# non-zero and does NOT touch git history itself. It runs as a step under
# nix-repo-base's update-locks framework (ul_run_step): a non-zero exit makes
# the framework roll back that step and mark the whole run failed, so the
# workflow's PR step never fires. A self-managed `git reset --hard HEAD~1`
# was removed (bead pg2-iy3yf): it assumed HEAD was always the nvfetcher
# commit, but when the nvfetcher step is TTL-skipped HEAD~1 is an unrelated
# (possibly unpushed) commit the reset would silently destroy. This helper is
# now purely read-only with respect to the git tree.
set -euo pipefail

# --- per-upstream method config (audit-time decision; 2026-06-18) ---
declare -A METHODS=(
  ["cmux"]="none-no-provenance-published"
  ["eclipse-java"]="none-no-provenance-published"
  ["lombok"]="none-no-provenance-published"
  ["logseq"]="checksums"
  ["tmux-open-nvim"]="git-source"
  ["tmux-mouse-swipe"]="git-source"
  ["tmux-nerd-font-window-name"]="git-source"
  ["bat-gherkin-syntax"]="git-source"
  ["pint"]="git-source"
  ["glowm"]="git-source"
)
declare -A REPOS=(
  ["cmux"]="manaflow-ai/cmux"
)

# Per-upstream basename of the release-dir hash manifest used by the `checksums`
# method. Upstreams do not agree on this name (logseq ships `SHA256SUMS.txt`),
# so it is configurable; keys absent here fall back to CHECKSUM_FILE_DEFAULT,
# which preserves the original hardcoded behavior for existing upstreams.
declare -A CHECKSUM_FILES=(
  ["logseq"]="SHA256SUMS.txt"
)
CHECKSUM_FILE_DEFAULT="checksums.txt"

# Resolve the hash-manifest basename for an upstream (override, else default).
checksum_file_for() {
  local key="$1"
  echo "${CHECKSUM_FILES[$key]:-$CHECKSUM_FILE_DEFAULT}"
}

# Extract the fetchurl `url` for a key from nvfetcher's generated.json.
# jq addresses the value by exact key, so — unlike the previous awk block
# scanner, which set in_block=1 but never reset it at the closing `}` — a
# package that lacks a url can never bleed into the NEXT package's url
# (pg2-xb4zc). Returns empty when the key has no url (e.g. git sources).
extract_url() {
  local key="$1"
  jq -r --arg k "$key" '.[$k].src.url // empty' _sources/generated.json
}

# Extract the recorded SRI hash (sha256 = "sha256-BASE64") for a key from
# nvfetcher's generated.json. Key-addressed, so no cross-package bleed
# (pg2-xb4zc). Returns empty when the key is absent or has no sha256.
extract_sri() {
  local key="$1"
  jq -r --arg k "$key" '.[$k].src.sha256 // empty' _sources/generated.json
}

# Assert a just-downloaded artifact hashes to the SRI nvfetcher pinned.
# Closes the TOCTOU gap (pg2-oqrus): verify_attestation/verify_sigstore
# re-download the artifact at verify time and prove *those* bytes carry a
# valid attestation/signature — but if upstream swapped the artifact between
# the nvfetcher fetch and this run, the verified bytes are NOT the bytes that
# will be built from the pinned sha256. Comparing the download to the pinned
# SRI (nvfetcher/fetchurl use a flat file hash, which `nix hash file` also
# emits) ties the provenance proof to the exact bytes the store will use.
verify_pinned_hash() {
  local key="$1" file="$2" recorded_sri actual_sri
  recorded_sri=$(extract_sri "$key")
  if [ -z "$recorded_sri" ]; then
    echo "verify-provenance: $key: could not extract recorded SRI hash" >&2
    return 1
  fi
  actual_sri=$(nix hash file --type sha256 --sri "$file")
  if [ "$actual_sri" != "$recorded_sri" ]; then
    echo "verify-provenance: $key: downloaded artifact hash '$actual_sri' does not match nvfetcher-pinned '$recorded_sri' — refusing to verify non-pinned bytes (TOCTOU)" >&2
    return 1
  fi
}

verify_attestation() {
  local key="$1" url
  url=$(extract_url "$key")
  if [ -z "$url" ]; then
    echo "verify-provenance: $key: could not extract URL from _sources/generated.json" >&2
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
  # Verify the downloaded bytes are the pinned bytes before trusting the
  # attestation over them (TOCTOU — pg2-oqrus).
  verify_pinned_hash "$key" "$tmpdir/artifact" || return 1
  if ! gh attestation verify "$tmpdir/artifact" --repo "${REPOS[$key]}" 2>&1; then
    echo "verify-provenance: $key: gh attestation verify failed" >&2
    return 1
  fi
}

verify_checksums() {
  local key="$1" url
  url=$(extract_url "$key")
  if [ -z "$url" ]; then
    echo "verify-provenance: $key: could not extract URL from _sources/generated.json" >&2
    return 1
  fi
  local recorded_sri
  recorded_sri=$(extract_sri "$key")
  if [ -z "$recorded_sri" ]; then
    echo "verify-provenance: $key: could not extract recorded SRI hash" >&2
    return 1
  fi
  local artifact_name release_base checksum_file
  artifact_name=$(basename "$url")
  release_base="${url%/"$artifact_name"}"
  # Upstreams disagree on the manifest basename (logseq: SHA256SUMS.txt), so
  # take a per-upstream override and fall back to the common default.
  checksum_file=$(checksum_file_for "$key")
  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064  # expand-now is intentional: $tmpdir is set just above.
  trap "rm -rf '$tmpdir'" RETURN
  if ! curl --location --silent --show-error --fail --output "$tmpdir/$checksum_file" "$release_base/$checksum_file"; then
    echo "verify-provenance: $key: failed to download $checksum_file from $release_base" >&2
    return 1
  fi
  local upstream_hex
  upstream_hex=$(awk -v name="$artifact_name" '
    { for (i = 1; i <= NF; i++) if ($i == name || $i == "*"name) { print $1; exit } }
  ' "$tmpdir/$checksum_file")
  if [ -z "$upstream_hex" ]; then
    echo "verify-provenance: $key: artifact '$artifact_name' not listed in $checksum_file" >&2
    return 1
  fi
  # hex -> SRI via `nix hash convert`, NOT the previous `xxd -r -p | base64`
  # pipeline. `xxd` ships with vim, not coreutils, so it is absent from the
  # sandboxed flake-check derivation and from a clean Linux runner — it only
  # appeared to work because macOS has /usr/bin/xxd. This path went unexercised
  # until logseq became the first `checksums` upstream. `nix` is unconditionally
  # available here (update-locks.sh itself drives `nix flake metadata`/`nix run`),
  # and this also drops the base64 portability dance.
  local upstream_sri
  if ! upstream_sri=$(nix hash convert --hash-algo sha256 --from base16 --to sri "$upstream_hex" 2>&1); then
    echo "verify-provenance: $key: could not convert upstream hash '$upstream_hex' from $checksum_file: $upstream_sri" >&2
    return 1
  fi
  if [ "$upstream_sri" != "$recorded_sri" ]; then
    echo "verify-provenance: $key: hash mismatch — nvfetcher recorded '$recorded_sri', upstream checksums.txt says '$upstream_sri' (hex: $upstream_hex)" >&2
    return 1
  fi
}

verify_sigstore() {
  local key="$1" url
  url=$(extract_url "$key")
  if [ -z "$url" ]; then
    echo "verify-provenance: $key: could not extract URL from _sources/generated.json" >&2
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
  # Verify the downloaded bytes are the pinned bytes before trusting the
  # signature over them (TOCTOU — pg2-oqrus).
  verify_pinned_hash "$key" "$tmpdir/artifact" || return 1
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
main() {
  local fail=0 key method
  for key in "${!METHODS[@]}"; do
    method="${METHODS[$key]}"
    case "$method" in
    # The verifying methods are silent on success, so log an explicit PASS line
    # for each. Without it a run shows only `skipped` lines plus a blanket
    # "all upstreams verified", making a genuinely-verified upstream
    # indistinguishable from one that was never configured.
    attestation)
      if verify_attestation "$key"; then
        echo "verify-provenance: $key: verified (GitHub attestation)"
      else
        fail=1
      fi
      ;;
    checksums)
      if verify_checksums "$key"; then
        echo "verify-provenance: $key: verified (pinned hash matches upstream $(checksum_file_for "$key"))"
      else
        fail=1
      fi
      ;;
    sigstore)
      if verify_sigstore "$key"; then
        echo "verify-provenance: $key: verified (cosign signature)"
      else
        fail=1
      fi
      ;;
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
    # Exit non-zero WITHOUT touching git history. Under ul_run_step this
    # rolls back the failed step and fails the whole update-locks run, so the
    # PR step never fires (see the header note on the removed HEAD~1 reset,
    # bead pg2-iy3yf).
    echo "verify-provenance: at least one upstream failed provenance check" >&2
    return 1
  fi

  echo "verify-provenance: all configured upstreams verified."
}

# Only run the verification loop when executed directly. Sourcing the script
# (e.g. from bats tests) defines the functions without running main.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi

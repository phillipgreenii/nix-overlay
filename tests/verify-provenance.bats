#!/usr/bin/env bats
# Tests for verify-provenance.sh (standalone update-locks helper).
#
# The script is sourced so its functions and config arrays are exercised in
# isolation; the BASH_SOURCE guard at the bottom keeps `main` from running on
# source (under bats $0 != the script path).

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../verify-provenance.sh"
  # shellcheck disable=SC1090  # runtime-computed path
  source "$SCRIPT"

  TEST_DIR="$(mktemp -d)"
  BIN_DIR="$(mktemp -d)"
  GIT_LOG="${BIN_DIR}/git-calls.log"
  # Record every git invocation. The pg2-iy3yf fix makes `main` purely
  # read-only w.r.t. the git tree, so it must never shell out to git.
  cat >"${BIN_DIR}/git" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"${GIT_LOG}"
exit 0
EOF
  chmod +x "${BIN_DIR}/git"
  PATH="${BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEST_DIR}" "${BIN_DIR}"
}

@test "main: git-source and none-no-provenance methods are skipped and pass" {
  # shellcheck disable=SC2034  # read by main() via dynamic scope after `run`
  declare -A METHODS=([foo]=git-source [bar]=none-no-provenance-published)
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"foo: skipped (git source"* ]]
  [[ "$output" == *"bar: skipped (no upstream provenance"* ]]
}

@test "main: an unknown method fails the run" {
  # shellcheck disable=SC2034  # read by main() via dynamic scope after `run`
  declare -A METHODS=([baz]=bogus-method)
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown method 'bogus-method'"* ]]
}

@test "main: never invokes git (no self-managed HEAD~1 rollback) even on failure" {
  # shellcheck disable=SC2034  # read by main() via dynamic scope after `run`
  declare -A METHODS=([baz]=bogus-method)
  run main
  [ "$status" -eq 1 ]
  # A recorded git call would mean main tried to mutate history — the exact
  # footgun pg2-iy3yf removed.
  [ ! -f "${GIT_LOG}" ]
}

# Write a _sources/generated.json fixture (the file jq now parses). Args are
# triples: <key> <url> <sri>. An empty <url> records a source with no url
# (like a git/github source), which is how the cross-package-bleed test
# builds a package that lacks the field the next package has.
write_generated_json() {
  mkdir -p "${TEST_DIR}/_sources"
  local json='{}'
  while [ "$#" -ge 3 ]; do
    local k="$1" u="$2" s="$3"
    shift 3
    if [ -z "$u" ]; then
      json=$(jq --arg k "$k" --arg s "$s" '.[$k] = { src: { sha256: $s } }' <<<"$json")
    else
      json=$(jq --arg k "$k" --arg u "$u" --arg s "$s" '.[$k] = { src: { url: $u, sha256: $s } }' <<<"$json")
    fi
  done
  printf '%s\n' "$json" >"${TEST_DIR}/_sources/generated.json"
}

# --- pg2-xb4zc: jq extraction is key-addressed, so no cross-package bleed ---

@test "extract_url/extract_sri: a package lacking a url does not bleed into the next" {
  # 'aaa' has no url (git-style source); 'zzz' has one. The old awk scanner
  # would return zzz's url when asked for aaa's; jq must return empty.
  write_generated_json \
    aaa "" "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" \
    zzz "https://example.invalid/zzz" "sha256-ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ="
  cd "${TEST_DIR}"

  run extract_url aaa
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run extract_url zzz
  [ "$output" = "https://example.invalid/zzz" ]

  run extract_sri aaa
  [ "$output" = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ]

  run extract_sri zzz
  [ "$output" = "sha256-ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ=" ]
}

@test "extract_sri: absent key returns empty" {
  write_generated_json zzz "https://example.invalid/zzz" "sha256-ZZZ="
  cd "${TEST_DIR}"
  run extract_sri nosuchkey
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- pg2-oqrus: verify_pinned_hash ties provenance to the pinned bytes ---

@test "verify_pinned_hash: passes when the download matches the pinned SRI" {
  local artifact="${TEST_DIR}/artifact"
  printf 'pinned bytes' >"$artifact"
  local sri
  sri=$(nix hash file --type sha256 --sri "$artifact")
  write_generated_json cmux "" "$sri"
  cd "${TEST_DIR}"
  run verify_pinned_hash cmux "$artifact"
  [ "$status" -eq 0 ]
}

@test "verify_pinned_hash: fails (TOCTOU) when the download differs from the pin" {
  local artifact="${TEST_DIR}/artifact"
  printf 'swapped bytes' >"$artifact"
  # Pin the SRI of DIFFERENT bytes than what was downloaded.
  local other="${TEST_DIR}/other"
  printf 'the originally pinned bytes' >"$other"
  local sri
  sri=$(nix hash file --type sha256 --sri "$other")
  write_generated_json cmux "" "$sri"
  cd "${TEST_DIR}"
  run verify_pinned_hash cmux "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match nvfetcher-pinned"* ]]
}

@test "verify_pinned_hash: fails when no SRI is recorded for the key" {
  local artifact="${TEST_DIR}/artifact"
  printf 'bytes' >"$artifact"
  write_generated_json someotherkey "" "sha256-AAAA"
  cd "${TEST_DIR}"
  run verify_pinned_hash cmux "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not extract recorded SRI"* ]]
}

# --- per-upstream checksum manifest basename (CHECKSUM_FILES) ---
#
# logseq publishes its release hash manifest as `SHA256SUMS.txt` rather than the
# `checksums.txt` this helper originally hardcoded, so the name is configurable.
# These tests pin BOTH the override and the default fallback, so generalizing it
# cannot silently regress the upstreams that use the default.

# NOTE on scoping: the script's `declare -A METHODS/REPOS/CHECKSUM_FILES` and
# `CHECKSUM_FILE_DEFAULT` run at its top level, but sourcing happens inside
# setup() — and bash's `declare` inside a function creates FUNCTION-LOCAL
# variables. So setup()'s source exposes the script's *functions* (definitions
# are global) but NOT its config arrays. Every test below that needs the real
# config, or calls a function that reads it, therefore sources the script again
# in its OWN body. The pre-existing tests never hit this because they inject
# their own local METHODS and read only generated.json.

# Stub `curl` to serve files out of a local directory by URL basename, so
# verify_checksums can be exercised without network. Mirrors the `git` stub in
# setup(): ${1} is expanded now, runtime ${...} are escaped.
stub_curl_serving() {
  cat >"${BIN_DIR}/curl" <<EOF
#!/usr/bin/env bash
out=""; url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --output) out="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
src="${1}/\$(basename "\$url")"
# 22 is curl's --fail exit status for an HTTP error, i.e. a missing manifest.
[ -f "\$src" ] || exit 22
cp "\$src" "\$out"
EOF
  chmod +x "${BIN_DIR}/curl"
}

# Record <hex>  <name> for an artifact into a manifest, and return its SRI.
write_manifest_for() {
  local serve_dir="$1" manifest="$2" artifact_name="$3" content="$4"
  local tmpfile="${TEST_DIR}/.artifact-${artifact_name}"
  printf '%s' "$content" >"$tmpfile"
  local sri hex
  sri=$(nix hash file --type sha256 --sri "$tmpfile")
  hex=$(nix hash convert --to base16 "$sri")
  mkdir -p "$serve_dir"
  printf '%s  %s\n' "$hex" "$artifact_name" >"${serve_dir}/${manifest}"
  printf '%s' "$sri"
}

@test "verify_checksums: uses the per-upstream manifest name (logseq: SHA256SUMS.txt)" {
  # See the scoping note above: re-source so the config arrays are in scope.
  # shellcheck disable=SC1090  # runtime-computed path
  source "$SCRIPT"
  local serve="${TEST_DIR}/serve"
  local sri
  sri=$(write_manifest_for "$serve" "SHA256SUMS.txt" "Logseq-darwin-arm64-2.0.1.dmg" "logseq bytes")
  write_generated_json logseq \
    "https://example.invalid/releases/download/2.0.1/Logseq-darwin-arm64-2.0.1.dmg" "$sri"
  stub_curl_serving "$serve"
  cd "${TEST_DIR}"

  run verify_checksums logseq
  [ "$status" -eq 0 ]
}

@test "verify_checksums: a key with no override still uses checksums.txt" {
  # See the scoping note above: re-source so the config arrays are in scope.
  # shellcheck disable=SC1090  # runtime-computed path
  source "$SCRIPT"
  local serve="${TEST_DIR}/serve"
  local sri
  sri=$(write_manifest_for "$serve" "checksums.txt" "thing-1.0.dmg" "thing bytes")
  # `unoverridden` is absent from CHECKSUM_FILES, so it must fall back.
  write_generated_json unoverridden "https://example.invalid/rel/1.0/thing-1.0.dmg" "$sri"
  stub_curl_serving "$serve"
  cd "${TEST_DIR}"

  run verify_checksums unoverridden
  [ "$status" -eq 0 ]
}

@test "verify_checksums: reports the configured manifest name when the artifact is unlisted" {
  # See the scoping note above: re-source so the config arrays are in scope.
  # shellcheck disable=SC1090  # runtime-computed path
  source "$SCRIPT"
  local serve="${TEST_DIR}/serve"
  # Manifest exists but lists a DIFFERENT artifact than the one being verified.
  write_manifest_for "$serve" "SHA256SUMS.txt" "some-other-file.zip" "other bytes" >/dev/null
  write_generated_json logseq \
    "https://example.invalid/releases/download/2.0.1/Logseq-darwin-arm64-2.0.1.dmg" \
    "sha256-l31ZkkpN/Z1Ok8dEZ/MlN4YyfIwo5pp18wzwQp2rd8c="
  stub_curl_serving "$serve"
  cd "${TEST_DIR}"

  run verify_checksums logseq
  [ "$status" -eq 1 ]
  [[ "$output" == *"not listed in SHA256SUMS.txt"* ]]
}

@test "verify_checksums: fails on a hash mismatch against the manifest" {
  # See the scoping note above: re-source so the config arrays are in scope.
  # shellcheck disable=SC1090  # runtime-computed path
  source "$SCRIPT"
  local serve="${TEST_DIR}/serve"
  write_manifest_for "$serve" "SHA256SUMS.txt" "Logseq-darwin-arm64-2.0.1.dmg" "the real bytes" >/dev/null
  # Pin the SRI of DIFFERENT bytes than the manifest records.
  local other="${TEST_DIR}/other"
  printf 'tampered bytes' >"$other"
  local wrong_sri
  wrong_sri=$(nix hash file --type sha256 --sri "$other")
  write_generated_json logseq \
    "https://example.invalid/releases/download/2.0.1/Logseq-darwin-arm64-2.0.1.dmg" "$wrong_sri"
  stub_curl_serving "$serve"
  cd "${TEST_DIR}"

  run verify_checksums logseq
  [ "$status" -eq 1 ]
  [[ "$output" == *"hash mismatch"* ]]
}

@test "checksum_file_for: returns the per-upstream override, else the default" {
  # See the scoping note above: re-source so the config arrays are in scope.
  # shellcheck disable=SC1090  # runtime-computed path
  source "$SCRIPT"

  run checksum_file_for logseq
  [ "$output" = "SHA256SUMS.txt" ]

  # cmux has no override, so it must resolve to the historical default.
  run checksum_file_for cmux
  [ "$output" = "checksums.txt" ]
}

@test "main: logs an explicit PASS line for a verified upstream" {
  # See the scoping note above: re-source so the config arrays are in scope.
  # shellcheck disable=SC1090  # runtime-computed path
  source "$SCRIPT"
  local serve="${TEST_DIR}/serve"
  local sri
  sri=$(write_manifest_for "$serve" "SHA256SUMS.txt" "Logseq-darwin-arm64-2.0.1.dmg" "logseq bytes")
  write_generated_json logseq \
    "https://example.invalid/releases/download/2.0.1/Logseq-darwin-arm64-2.0.1.dmg" "$sri"
  stub_curl_serving "$serve"
  cd "${TEST_DIR}"
  # Narrow METHODS to just logseq so main() does not reach the real upstreams.
  # shellcheck disable=SC2034  # read by main() via dynamic scope after `run`
  declare -A METHODS=([logseq]=checksums)

  run main
  [ "$status" -eq 0 ]
  # A verified upstream must be visibly distinguishable from a skipped one.
  [[ "$output" == *"logseq: verified (pinned hash matches upstream SHA256SUMS.txt)"* ]]
}

# --- live config assertions (guard the audited wiring, not the mechanism) ---

@test "config: logseq is verified via checksums against SHA256SUMS.txt" {
  # See the scoping note above: re-source so the config arrays are in scope.
  # shellcheck disable=SC1090  # runtime-computed path
  source "$SCRIPT"
  # Not none-no-provenance-published: logseq DOES publish a hash manifest, so a
  # regression to the "documented gap" bucket would silently stop verifying it.
  [ "${METHODS[logseq]}" = "checksums" ]
  [ "${CHECKSUM_FILES[logseq]}" = "SHA256SUMS.txt" ]
}

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

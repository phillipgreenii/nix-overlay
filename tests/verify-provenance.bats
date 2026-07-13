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

# --- pg2-oqrus: verify_pinned_hash ties provenance to the pinned bytes ---

# Write a minimal _sources/generated.nix block (matching the real nvfetcher
# layout the awk parser expects) recording <sri> for <key>.
write_generated_nix() {
  local key="$1" sri="$2"
  mkdir -p "${TEST_DIR}/_sources"
  cat >"${TEST_DIR}/_sources/generated.nix" <<EOF
{
  ${key} = {
    pname = "${key}";
    version = "1.0";
    src = fetchurl {
      url = "https://example.invalid/${key}";
      sha256 = "${sri}";
    };
  };
}
EOF
}

@test "verify_pinned_hash: passes when the download matches the pinned SRI" {
  local artifact="${TEST_DIR}/artifact"
  printf 'pinned bytes' >"$artifact"
  local sri
  sri=$(nix hash file --type sha256 --sri "$artifact")
  write_generated_nix cmux "$sri"
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
  write_generated_nix cmux "$sri"
  cd "${TEST_DIR}"
  run verify_pinned_hash cmux "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match nvfetcher-pinned"* ]]
}

@test "verify_pinned_hash: fails when no SRI is recorded for the key" {
  local artifact="${TEST_DIR}/artifact"
  printf 'bytes' >"$artifact"
  write_generated_nix someotherkey "sha256-AAAA"
  cd "${TEST_DIR}"
  run verify_pinned_hash cmux "$artifact"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not extract recorded SRI"* ]]
}

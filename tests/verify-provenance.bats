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

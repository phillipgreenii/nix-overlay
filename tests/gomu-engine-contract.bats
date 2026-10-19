#!/usr/bin/env bats
# bats file_tags=type:integration
# Contract between pg-go-mutate (phillipg-nix-repo-base) and the REAL gomu engine
# this overlay builds. pg-go-mutate's own suites run against a stub engine, so a
# gomu release that changes what the binary actually reports -- its version line,
# its flags, the shape of mutation-report.json -- leaves them green while every
# real run breaks. This suite is the one place the two meet.
#
# It asserts only what pg-go-mutate relies on, never mutant COUNTS: gomu adds
# mutators between releases, so a count would fail on every bump.
#
# The target project is GENERATED into BATS_FILE_TMPDIR at run time, so no .go
# file ever exists in this repo for `go test ./...`, gofmt, golangci-lint or the
# unit-tier commit hook to find. The type:integration tag keeps pg-test-runner's
# default (unit) selection away from it too; the nix check
# `gomu-engine-contract-tests` (flake.nix) is what runs it.
#
# Environment (set by that check):
#   GOMU_CONTRACT_PG_GO_MUTATE  path to the pg-go-mutate executable under test
#   GOMU_CONTRACT_REQUIRED=1    turn "tool missing" skips into failures, so the
#                               nix check can never pass vacuously
# plus PG_GO_MUTATE_GOMU (the engine under test), `go` and `jq` on PATH.

setup_file() {
  if ! _have_tools; then
    return 0
  fi

  export HOME="$BATS_FILE_TMPDIR/home"
  export PGM_SEM_DIR="$BATS_FILE_TMPDIR/sem"
  export PGM_GUARD_CACHE_DIR="$BATS_FILE_TMPDIR/guard-cache"
  export PGM_CONFIG_PATH="$BATS_FILE_TMPDIR/no-config.json"
  # Hermetic Go: the fixture has no dependencies, so nothing may touch a network
  # or a toolchain download, and no C compiler is needed.
  export GOCACHE="$BATS_FILE_TMPDIR/gocache"
  export GOPATH="$BATS_FILE_TMPDIR/gopath"
  export GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local CGO_ENABLED=0
  mkdir -p "$HOME"

  TARGET="$BATS_FILE_TMPDIR/fx"
  mkdir -p "$TARGET"
  printf 'module fx\n\ngo 1.21\n' >"$TARGET/go.mod"

  # One function, kept as small as it can be while still giving BOTH outcomes:
  # the test asserts Pos(1), so flipping `>` to `<=` fails it (KILLED), while the
  # boundary mutants (`>=`, `!=`) agree with Pos(1) and so SURVIVE. Size matters:
  # every mutant costs one `go test` run, which is most of this suite's runtime.
  cat >"$TARGET/fx.go" <<'GO'
package fx

func Pos(n int) bool { return n > 0 }
GO
  cat >"$TARGET/fx_test.go" <<'GO'
package fx

import "testing"

func TestPos(t *testing.T) {
	if !Pos(1) {
		t.Fatal("Pos(1) is false")
	}
}
GO
  FN_LINE="$(grep -n '^func Pos' "$TARGET/fx.go" | cut -d: -f1)"

  # One engine run for the whole file: every mutant is a `go test`, so running it
  # per test would multiply the only slow step.
  REPORT="$BATS_FILE_TMPDIR/report.json"
  set +e
  "$GOMU_CONTRACT_PG_GO_MUTATE" "$TARGET" --json >"$REPORT" 2>"$BATS_FILE_TMPDIR/stderr.log"
  echo "$?" >"$BATS_FILE_TMPDIR/exit"
  set -e

  export TARGET FN_LINE REPORT
}

_have_tools() {
  local missing=""
  [ -x "${GOMU_CONTRACT_PG_GO_MUTATE:-}" ] || missing="$missing GOMU_CONTRACT_PG_GO_MUTATE"
  [ -x "${PG_GO_MUTATE_GOMU:-}" ] || missing="$missing PG_GO_MUTATE_GOMU"
  command -v go >/dev/null 2>&1 || missing="$missing go"
  command -v jq >/dev/null 2>&1 || missing="$missing jq"
  [ -z "$missing" ] && return 0
  MISSING_TOOLS="$missing"
  return 1
}

setup() {
  if ! _have_tools; then
    if [ "${GOMU_CONTRACT_REQUIRED:-}" = 1 ]; then
      echo "required tooling missing:$MISSING_TOOLS" >&2
      return 1
    fi
    skip "needs the real engine and pg-go-mutate (run via the gomu-engine-contract-tests flake check); missing:$MISSING_TOOLS"
  fi
  export HOME="$BATS_FILE_TMPDIR/home"
  export PGM_SEM_DIR="$BATS_FILE_TMPDIR/sem"
  export PGM_GUARD_CACHE_DIR="$BATS_FILE_TMPDIR/guard-cache"
  export PGM_CONFIG_PATH="$BATS_FILE_TMPDIR/no-config.json"
  export GOCACHE="$BATS_FILE_TMPDIR/gocache"
  export GOPATH="$BATS_FILE_TMPDIR/gopath"
  export GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local CGO_ENABLED=0
}

@test "the pinned engine is accepted and the analysis completes (E1 handshake against the real version line)" {
  [ "$(cat "$BATS_FILE_TMPDIR/exit")" = 0 ] || {
    cat "$BATS_FILE_TMPDIR/stderr.log" >&2
    return 1
  }
  jq -e . "$REPORT" >/dev/null
}

@test "an engine reporting any other version is refused before any mutant runs" {
  PG_GO_MUTATE_GOMU_VERSION=0.0.0-not-the-engine \
    run "$GOMU_CONTRACT_PG_GO_MUTATE" "$TARGET" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"engine version mismatch"* ]]
}

@test "the report keeps the fields pg-go-mutate reads for each survivor" {
  run jq -e '.survivors | length > 0 and all(.[]; (.file|type=="string") and (.line|type=="number") and (.type|type=="string") and (.description|type=="string"))' "$REPORT"
  [ "$status" -eq 0 ]
}

@test "statistics keeps the integer counters pg-go-mutate reads" {
  run jq -e '.statistics | all(.killed, .survived, .timedOut, .errors, .notViable; type=="number")' "$REPORT"
  [ "$status" -eq 0 ]
}

@test "a mutant the tests miss is reported as a survivor, at the line it mutated" {
  run jq -e --argjson l "$FN_LINE" '[.survivors[] | select(.file=="fx.go" and .line==$l)] | length > 0' "$REPORT"
  [ "$status" -eq 0 ]
}

@test "a mutant that makes a test fail is counted as killed, not reported" {
  run jq -e '.statistics.killed > 0' "$REPORT"
  [ "$status" -eq 0 ]
}

@test "the engine writes nothing into the target directory (its report and history stay in the private cwd)" {
  run ls -A "$TARGET"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | LC_ALL=C sort | tr '\n' ' ')" = "fx.go fx_test.go go.mod " ]
}

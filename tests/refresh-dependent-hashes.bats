#!/usr/bin/env bats
# bats file_tags=type:unit
# Pure (no nix) tests for refresh-dependent-hashes.sh: the text helpers, the
# revert logic, and the registry drift guards that keep the inventory of
# source-dependent fixed-output hashes complete (bead pg2-g39wh).
#
# The step itself -- real `nix build`, real `got:` mismatch output -- is
# exercised against a fixture flake in refresh-dependent-hashes-nix.bats.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/refresh-dependent-hashes.sh"
  # shellcheck disable=SC1090  # runtime-computed path
  source "$SCRIPT"
  TEST_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEST_DIR}"
}

# --- hash literal helpers ---

@test "rdh_get_hash: reads the literal and does not confuse hash with vendorHash" {
  cat >"${TEST_DIR}/default.nix" <<'EOF'
{
  vendorHash = "sha256-VENDOR";
  pnpmDeps = fetchPnpmDeps {
    hash = "sha256-PNPM";
  };
}
EOF
  [ "$(rdh_get_hash "${TEST_DIR}/default.nix" hash)" = "sha256-PNPM" ]
  [ "$(rdh_get_hash "${TEST_DIR}/default.nix" vendorHash)" = "sha256-VENDOR" ]
}

@test "rdh_get_hash: fails when the literal is missing or ambiguous" {
  printf 'hash = "sha256-A";\nhash = "sha256-B";\n' >"${TEST_DIR}/two.nix"
  printf '{ }\n' >"${TEST_DIR}/none.nix"
  run rdh_get_hash "${TEST_DIR}/two.nix" hash
  [ "$status" -ne 0 ]
  run rdh_get_hash "${TEST_DIR}/none.nix" hash
  [ "$status" -ne 0 ]
}

@test "rdh_set_hash: rewrites only the named literal" {
  cat >"${TEST_DIR}/default.nix" <<'EOF'
{
  vendorHash = "sha256-VENDOR";
  other = "sha256-KEEP";
  hash = "sha256-OLD";
}
EOF
  rdh_set_hash "${TEST_DIR}/default.nix" hash "sha256-NEW"
  [ "$(rdh_get_hash "${TEST_DIR}/default.nix" hash)" = "sha256-NEW" ]
  [ "$(rdh_get_hash "${TEST_DIR}/default.nix" vendorHash)" = "sha256-VENDOR" ]
  grep -qF 'other = "sha256-KEEP";' "${TEST_DIR}/default.nix"
}

# --- build log classification ---

@test "rdh_classify_log: pnpm minimumReleaseAge is its own class and beats a mismatch" {
  cat >"${TEST_DIR}/age.log" <<'EOF'
foo-pnpm-deps> ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION  mermaid@12.2.0 was published at 2026-10-13T08:32:46.000Z
error: hash mismatch in fixed-output derivation
            got:    sha256-AAAA
EOF
  [ "$(rdh_classify_log "${TEST_DIR}/age.log")" = "age" ]
}

@test "rdh_classify_log: a fixed-output mismatch is 'mismatch', anything else 'other'" {
  cat >"${TEST_DIR}/mismatch.log" <<'EOF'
error: hash mismatch in fixed-output derivation '/nix/store/x.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
EOF
  printf 'error: builder for x.drv failed with exit code 2\n' >"${TEST_DIR}/other.log"
  [ "$(rdh_classify_log "${TEST_DIR}/mismatch.log")" = "mismatch" ]
  [ "$(rdh_classify_log "${TEST_DIR}/other.log")" = "other" ]
}

@test "rdh_mismatch_pair: returns specified and got of the last mismatch" {
  cat >"${TEST_DIR}/m.log" <<'EOF'
         specified: sha256-FIRSTSPEC
            got:    sha256-FIRSTGOT
         specified: sha256-LASTSPEC
            got:    sha256-LASTGOT
EOF
  [ "$(rdh_mismatch_pair "${TEST_DIR}/m.log")" = "sha256-LASTSPEC sha256-LASTGOT" ]
}

# --- per-key revert ---

@test "rdh_restore_key: puts one key back byte-for-byte and leaves the others alone" {
  mkdir -p "${TEST_DIR}/_sources" "${TEST_DIR}/packages/a"
  RDH_BASE="${TEST_DIR}/base"
  RDH_SOURCES_DIR="${TEST_DIR}/_sources"
  # shellcheck disable=SC2034  # read by rdh_restore_key
  HASH_DEPS=(["a"]="${TEST_DIR}/packages/a/default.nix:hash:a")
  mkdir -p "${RDH_BASE}/files/${TEST_DIR}/packages/a"

  cat >"${RDH_BASE}/generated.nix" <<'EOF'
{
  a = {
    pname = "a";
    version = "1";
  };
  b = {
    pname = "b";
    version = "1";
  };
}
EOF
  jq --indent 4 -S -n '{a:{pname:"a",version:"1"},b:{pname:"b",version:"1"}}' | tr -d '\n' >"${RDH_BASE}/generated.json"
  printf 'hash = "sha256-OLD";\n' >"${RDH_BASE}/files/${TEST_DIR}/packages/a/default.nix"

  # Current tree: both keys bumped, a's hash refreshed.
  sed 's/version = "1"/version = "2"/' "${RDH_BASE}/generated.nix" >"${RDH_SOURCES_DIR}/generated.nix"
  jq --indent 4 -S '.a.version = "2" | .b.version = "2"' "${RDH_BASE}/generated.json" | tr -d '\n' >"${RDH_SOURCES_DIR}/generated.json"
  printf 'hash = "sha256-NEW";\n' >"${TEST_DIR}/packages/a/default.nix"

  rdh_restore_key a

  # a is back to the snapshot; b keeps its bump.
  [ "$(jq -r '.a.version' "${RDH_SOURCES_DIR}/generated.json")" = "1" ]
  [ "$(jq -r '.b.version' "${RDH_SOURCES_DIR}/generated.json")" = "2" ]
  awk '/^  a = \{/,/^  \};/' "${RDH_SOURCES_DIR}/generated.nix" | grep -qF 'version = "1"'
  awk '/^  b = \{/,/^  \};/' "${RDH_SOURCES_DIR}/generated.nix" | grep -qF 'version = "2"'
  [ "$(rdh_get_hash "${TEST_DIR}/packages/a/default.nix" hash)" = "sha256-OLD" ]
}

# --- registry drift guards (the inventory of source-dependent hashes) ---

@test "registry: every nvfetcher.toml key has a BUILD_ATTRS entry and vice versa" {
  local toml_keys reg_keys
  toml_keys=$(sed -nE 's/^\[([A-Za-z0-9_.-]+)\]$/\1/p' "${REPO_ROOT}/nvfetcher.toml" | sort)
  reg_keys=$(printf '%s\n' "${!BUILD_ATTRS[@]}" | sort)
  [ "$toml_keys" = "$reg_keys" ]
}

@test "registry: every BUILD_ATTRS package is exposed by flake.nix" {
  local key attr
  for key in "${!BUILD_ATTRS[@]}"; do
    for attr in ${BUILD_ATTRS[$key]}; do
      grep -qE "(^|[^A-Za-z0-9_-])${attr}([^A-Za-z0-9_-]|\$)" "${REPO_ROOT}/flake.nix" || {
        echo "BUILD_ATTRS[$key] names '$attr', which flake.nix does not mention" >&2
        return 1
      }
    done
  done
}

@test "registry: every HASH_DEPS entry points at exactly one literal in a real file" {
  local key entry file rest attr
  for key in "${!HASH_DEPS[@]}"; do
    [ -n "${BUILD_ATTRS[$key]+x}" ] || {
      echo "HASH_DEPS[$key] has no BUILD_ATTRS entry" >&2
      return 1
    }
    for entry in ${HASH_DEPS[$key]}; do
      file="${entry%%:*}"
      rest="${entry#*:}"
      attr="${rest%%:*}"
      rdh_get_hash "${REPO_ROOT}/${file}" "$attr" >/dev/null || {
        echo "HASH_DEPS[$key]: no single '$attr' literal in $file" >&2
        return 1
      }
    done
  done
}

@test "registry: every package carrying a source-dependent hash or lock is registered" {
  # The set of package dirs that hold a fixed-output hash literal, a pnpm/npm/
  # yarn dependency fetch, or a cargo lock must equal the registered set.
  local found registered key entry
  found=$(cd "${REPO_ROOT}" && grep -rlE '^[[:space:]]*(vendorHash|npmDepsHash|cargoHash|cargoSha256|yarnHash|outputHash|hash) = "sha256-|fetchPnpmDeps|fetchNpmDeps|fetchYarnDeps|fetchCargoVendor|cargoLock\.' packages --include=default.nix | xargs -n1 dirname | sort -u)
  registered=$(
    for key in "${!HASH_DEPS[@]}"; do
      for entry in ${HASH_DEPS[$key]}; do dirname "${entry%%:*}"; done
    done
    for key in "${!MANUAL_DEPS[@]}"; do dirname "${MANUAL_DEPS[$key]}"; done
  )
  registered=$(printf '%s\n' "$registered" | sort -u)
  if [ "$found" != "$registered" ]; then
    echo "package dirs with source-dependent hashes/locks: $(echo $found)" >&2
    echo "dirs registered in HASH_DEPS/MANUAL_DEPS:        $(echo $registered)" >&2
    return 1
  fi
}

@test "registry: the inventory doc names every registered hash file and lock" {
  local doc="${REPO_ROOT}/docs/update-locks-dependent-hashes.md" key entry
  [ -f "$doc" ]
  for key in "${!HASH_DEPS[@]}"; do
    for entry in ${HASH_DEPS[$key]}; do
      grep -qF "${entry%%:*}" "$doc" || {
        echo "docs/update-locks-dependent-hashes.md does not mention ${entry%%:*}" >&2
        return 1
      }
    done
  done
  for key in "${!MANUAL_DEPS[@]}"; do
    grep -qF "${MANUAL_DEPS[$key]}" "$doc" || {
      echo "docs/update-locks-dependent-hashes.md does not mention ${MANUAL_DEPS[$key]}" >&2
      return 1
    }
  done
}

@test "registry: every PIN_GUARDS entry has a BUILD_ATTRS entry, a real flake.lock input, and a doc mention" {
  local key spec input file doc="${REPO_ROOT}/docs/update-locks-dependent-hashes.md"
  [ "${#PIN_GUARDS[@]}" -gt 0 ]
  for key in "${!PIN_GUARDS[@]}"; do
    spec="${PIN_GUARDS[$key]}"
    input="${spec%%:*}"
    file="${spec#*:}"
    [ -n "${BUILD_ATTRS[$key]+x}" ] || {
      echo "PIN_GUARDS[$key] has no BUILD_ATTRS entry" >&2
      return 1
    }
    jq -e --arg i "$input" '.nodes.root.inputs[$i] as $n | ($n | type) == "string" and .nodes[$n].locked != null' "${REPO_ROOT}/flake.lock" >/dev/null || {
      echo "PIN_GUARDS[$key]: flake.lock has no locked input '$input'" >&2
      return 1
    }
    grep -qF "$file" "$doc" || {
      echo "docs/update-locks-dependent-hashes.md does not mention the pin file $file" >&2
      return 1
    }
  done
}

@test "update-locks.sh runs the nvfetcher step through refresh-dependent-hashes.sh with the provenance gate" {
  grep -qE 'refresh-dependent-hashes\.sh"? +--gate' "${REPO_ROOT}/update-locks.sh"
}
